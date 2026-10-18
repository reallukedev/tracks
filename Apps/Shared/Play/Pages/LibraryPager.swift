import SwiftUI
import MusicKit
import TracksCore

// MARK: - Fetching

/// Reads the Apple Music library a page at a time, never sorted. On the Mac, MusicKit turns
/// a library request's sort descriptors into iTunes library ones, and for some key paths that
/// raises an Objective-C exception no Swift code can catch, ending the app. So the Mac asks
/// for everything unsorted and puts it in order in Swift (``LibrarySort``).
nonisolated enum LibraryFetch {
    static func pages<Item: MusicLibraryRequestable & Sendable>(_: Item.Type, batch: Int) -> AsyncThrowingStream<[Item], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if DEBUG
                    if let demo = LibraryDemo.items(Item.self) {
                        // `-TracksLibraryDelay 1.5`: as long as a real library takes to answer.
                        let delay = UserDefaults.standard.double(forKey: "TracksLibraryDelay")
                        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                        continuation.yield(demo)
                        continuation.finish()
                        return
                    }
                    #endif
                    var request = MusicLibraryRequest<Item>()
                    request.limit = batch
                    var page = try await request.response().items
                    continuation.yield(Array(page))
                    while page.hasNextBatch, !Task.isCancelled, let more = try await page.nextBatch(limit: batch) {
                        continuation.yield(Array(more))
                        page = more
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Everything of one kind in the Apple Music library, gathered in the background and kept for
/// the session, so moving between Albums, Artists and search doesn't read the library again.
/// Comes back to it after a couple of minutes, keeping what's shown until the new read is whole.
@MainActor
@Observable
final class LibraryGatherer<Item: MusicLibraryRequestable & Sendable> {
    /// In the library's own order, which is no order at all.
    private(set) var items: [Item] = []
    /// Bumped whenever ``items`` changes, for the pages arranging them.
    private(set) var revision = 0
    private(set) var hasLoaded = false
    private(set) var isComplete = false
    private(set) var failed = false
    @ObservationIgnored private var gathering: Task<Void, Never>?
    @ObservationIgnored private var gatheredAt: ContinuousClock.Instant?

    /// Big pages: there's no network between Tracks and the library.
    private static var batch: Int { 500 }
    /// How long a whole read stays good.
    private static var freshness: Duration { .seconds(120) }
    /// How long a first read waits to be whole before showing what's come so far, which
    /// then settles into place as the rest arrives.
    private static var patience: Duration { .seconds(1.5) }

    /// Reads the library, unless it was read lately or is being read now.
    func gather() async {
        if let gathering {
            await gathering.value
            return
        }
        if isComplete, let gatheredAt, ContinuousClock.now - gatheredAt < Self.freshness { return }
        let task = Task { await run() }
        gathering = task
        await task.value
        gathering = nil
    }

    /// Forgets what was read, for Try Again.
    func retry() async {
        gatheredAt = nil
        isComplete = false
        await gather()
    }

    private func run() async {
        let started = ContinuousClock.now
        var shown = started
        // A refresh keeps the whole library on screen rather than a part of the new read.
        let showsPartial = !hasLoaded
        failed = false
        var collected: [Item] = []
        // Pages can repeat an item, and a list mustn't show one id twice, even part way.
        var seen = Set<MusicItemID>()
        do {
            for try await page in LibraryFetch.pages(Item.self, batch: Self.batch) {
                collected += page.filter { seen.insert($0.id).inserted }
                let now = ContinuousClock.now
                if showsPartial, now - started > Self.patience, now - shown > .seconds(1) {
                    publish(collected, isComplete: false)
                    shown = now
                }
            }
            publish(collected, isComplete: true)
            gatheredAt = .now
        } catch {
            if items.isEmpty { failed = true }
            hasLoaded = true
        }
    }

    private func publish(_ gathered: [Item], isComplete: Bool) {
        items = gathered
        revision += 1
        hasLoaded = true
        self.isComplete = isComplete
    }
}

/// The library's gatherers, one per kind, for the whole app.
@MainActor
enum LibraryCache {
    private static var gatherers: [ObjectIdentifier: AnyObject] = [:]

    static func gatherer<Item: MusicLibraryRequestable & Sendable>(for _: Item.Type) -> LibraryGatherer<Item> {
        if let known = gatherers[ObjectIdentifier(Item.self)] as? LibraryGatherer<Item> { return known }
        let made = LibraryGatherer<Item>()
        gatherers[ObjectIdentifier(Item.self)] = made
        return made
    }
}

// MARK: - A page's items

/// One kind of library item as a page lists it: filtered and in the order chosen.
///
/// Two ways to get there. Gathering (always on the Mac, and for artists everywhere) reads the
/// whole library once, unsorted, and sorts and filters it in Swift, off the main actor. On
/// iPhone, songs, albums and playlists instead ask Apple Music for one sorted, filtered page at
/// a time as the list scrolls, which starts faster on a big library.
@MainActor
@Observable
final class LibraryPager<Item: MusicLibraryRequestable & Sendable> {
    private(set) var items: [Item] = [] {
        didSet { revision += 1 }
    }
    /// Bumped whenever ``items`` changes, for a page that keeps something made from them.
    private(set) var revision = 0
    private(set) var isLoading = false
    private(set) var failed = false
    /// The next page couldn't be fetched. It's kept, to ask again.
    private(set) var loadMoreFailed = false
    /// False until the first items for the current query arrive.
    private(set) var hasLoaded = false
    /// Bumped by Try Again, so the page asks again.
    private(set) var attempt = 0
    /// Nil when the page asks Apple Music a page at a time.
    let gatherer: LibraryGatherer<Item>?
    @ObservationIgnored private var next: MusicItemCollection<Item>?
    /// Bumped by each new query or order, so work still running for the last one is thrown away.
    @ObservationIgnored private var generation = 0
    /// The query the items are for.
    @ObservationIgnored private var loadedQuery = ""

    init(gathers: Bool = LibraryPager.gathersEverything) {
        gatherer = gathers ? LibraryCache.gatherer(for: Item.self) : nil
    }

    /// Whether pages gather the whole library rather than asking for sorted pages: on the Mac,
    /// where sorted requests can crash, and for the sample library, which can't sort.
    nonisolated static var gathersEverything: Bool {
        #if os(macOS)
        true
        #else
        LibraryDemo.isOn
        #endif
    }

    /// The items for a query in an order: arranged from what's gathered, or asked of Apple
    /// Music with `server` putting the request in order.
    func load(
        query: String,
        order: LibraryOrder,
        server: ((inout MusicLibraryRequest<Item>) -> Void)?,
        keys: @escaping @Sendable (Item) -> LibrarySortKeys
    ) async {
        generation += 1
        let asked = generation
        defer { if asked == generation { loadedQuery = query.trimmingCharacters(in: .whitespaces) } }
        if let gatherer {
            guard gatherer.hasLoaded else { return }
            let arranged = await Self.arranged(gatherer.items, query: query, order: order, keys: keys)
            guard asked == generation else { return }
            items = arranged
            failed = gatherer.failed
            hasLoaded = true
            return
        }
        next = nil
        loadMoreFailed = false
        isLoading = true
        failed = false
        defer { if asked == generation { isLoading = false } }
        var request = MusicLibraryRequest<Item>()
        request.limit = 100
        server?(&request)
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { request.filter(text: text) }
        do {
            let response = try await request.response()
            guard asked == generation else { return }
            items = Array(response.items)
            next = response.items.hasNextBatch ? response.items : nil
        } catch {
            guard asked == generation else { return }
            failed = true
        }
        hasLoaded = true
    }

    @concurrent
    private nonisolated static func arranged(
        _ items: [Item],
        query: String,
        order: LibraryOrder,
        keys: @Sendable (Item) -> LibrarySortKeys
    ) async -> [Item] {
        LibrarySort.sorted(LibrarySort.filtered(items, matching: query, keys: keys), by: order, keys: keys)
    }

    func retry(query: String) async {
        if let gatherer {
            await gatherer.retry()
        } else {
            failed = false
            hasLoaded = false
            attempt += 1
        }
    }

    /// Every item, up to `limit`, loading the pages not seen yet. For Shuffle All, which
    /// shouldn't only shuffle the first screenful.
    func all(upTo limit: Int) async -> [Item] {
        if let gatherer { return Array(gatherer.items.prefix(limit)) }
        var gathered = items
        var batch = next
        while gathered.count < limit, let current = batch, let more = try? await current.nextBatch() {
            gathered += more
            batch = more.hasNextBatch ? more : nil
        }
        return Array(gathered.prefix(limit))
    }

    /// Loads every page up to `limit` into ``items``, for an order Apple Music can't keep
    /// itself (your plays).
    func loadAll(upTo limit: Int) async {
        loadMoreFailed = false
        while next != nil, items.count < limit, !Task.isCancelled, !loadMoreFailed {
            // A page already being fetched: wait for it rather than spin.
            if isLoading {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            await loadNext()
        }
    }

    var hasMore: Bool { next != nil || gatherer?.isComplete == false }

    /// The next page, when a row near the end appears.
    func loadMore(after item: Item) async {
        guard next != nil, !isLoading,
              let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 20
        else { return }
        await loadNext()
    }

    /// The next page, whatever's on screen.
    func loadNext() async {
        guard let batch = next, !isLoading else { return }
        let asked = generation
        isLoading = true
        defer { isLoading = false }
        let more = try? await batch.nextBatch()
        guard asked == generation else { return }
        guard let more else {
            // Kept to ask again: a dropped connection mustn't end the list as if it were whole.
            if !Task.isCancelled { loadMoreFailed = true }
            return
        }
        loadMoreFailed = false
        let known = Set(items.map(\.id))
        items += more.filter { !known.contains($0.id) }
        next = more.hasNextBatch ? more : nil
    }

    /// Where the page stands, or where `-TracksLibraryState` says it does.
    var phase: LibraryPhase {
        if let forced = LibraryDebugState.current {
            switch forced {
            case .loading: return .loading
            case .empty: return .empty
            case .failed: return .failed
            }
        }
        if let gatherer, gatherer.failed, gatherer.items.isEmpty { return .failed }
        if failed, items.isEmpty { return .failed }
        if !hasLoaded { return .loading }
        if items.isEmpty, !isLoading { return .empty }
        return .ready
    }

    /// Whether the library itself has nothing of this kind, rather than nothing matching.
    var isLibraryEmpty: Bool {
        if let gatherer { return gatherer.isComplete && gatherer.items.isEmpty }
        return items.isEmpty && loadedQuery.isEmpty
    }

    /// "2,431 songs" once they're all counted; "100 songs and more" on iPhone while there are
    /// pages still to come; nothing while the Mac is still reading.
    func count(_ noun: (Int) -> String) -> String? {
        guard phase == .ready else { return nil }
        if let gatherer {
            return gatherer.isComplete ? noun(gatherer.items.count) : nil
        }
        let counted = noun(items.count)
        return next != nil ? String(localized: "\(counted) and more") : counted
    }
}

enum LibraryPhase {
    case loading, failed, empty, ready
}

/// A library page's content, or the state it's in instead: loading in the shape of what's
/// coming, couldn't load, an empty library, or nothing matching the filter.
struct LibraryPagerContent<Item: MusicLibraryRequestable & Sendable, Loading: View, Content: View>: View {
    let pager: LibraryPager<Item>
    let query: String
    let section: LibrarySection
    /// On iPhone, whether `content` is the rows of a list. The list is then the page from its
    /// first frame, with the state as its one row until the rows arrive
    /// (see `libraryStateRow()`).
    var isList = false
    @ViewBuilder var loading: Loading
    @ViewBuilder var content: Content

    var body: some View {
        #if os(iOS)
        if isList {
            List {
                if pager.phase == .ready {
                    content
                } else {
                    state.libraryStateRow()
                }
            }
            .listStyle(.plain)
        } else {
            contentOrState
        }
        #else
        contentOrState
        #endif
    }

    @ViewBuilder
    private var contentOrState: some View {
        if pager.phase == .ready {
            content
        } else {
            state
        }
    }

    @ViewBuilder
    private var state: some View {
        switch pager.phase {
        case .loading: loading
        case .failed: LibraryLoadFailed { await pager.retry(query: query) }
        case .empty:
            if pager.isLibraryEmpty || LibraryDebugState.current == .empty {
                LibraryEmptyAppleMusic(section: section)
            } else {
                LibraryNoMatches(query: query)
            }
        case .ready: EmptyView()
        }
    }
}

/// Keeps a pager's items current: reads the library in the background where the page gathers
/// it, then arranges or asks again for each query, order and read, a moment after typing stops.
private struct LibraryPagerLoader<Item: MusicLibraryRequestable & Sendable>: ViewModifier {
    let pager: LibraryPager<Item>
    let query: String
    let order: LibraryOrder
    /// Anything else the items depend on, such as your plays.
    let key: String
    let server: ((inout MusicLibraryRequest<Item>) -> Void)?
    let keys: @Sendable (Item) -> LibrarySortKeys

    func body(content: Content) -> some View {
        content
            .task {
                await pager.gatherer?.gather()
            }
            .task(id: "\(query)\u{1F}\(order.rawValue)\u{1F}\(key)\u{1F}\(pager.gatherer?.revision ?? -1)\u{1F}\(pager.attempt)") {
                // Filtering what's gathered is quick; asking Apple Music waits for a pause.
                let pause = pager.gatherer == nil ? 250 : 60
                try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : pause))
                guard !Task.isCancelled else { return }
                await pager.load(query: query, order: order, server: server, keys: keys)
            }
    }
}

extension View {
    /// Loads `pager` for the query, in `order`: sorted in Swift when it gathers, or by
    /// `server` when it asks Apple Music.
    func loads<Item>(
        _ pager: LibraryPager<Item>,
        query: String,
        order: LibraryOrder,
        key: String = "",
        server: ((inout MusicLibraryRequest<Item>) -> Void)? = nil,
        keys: @escaping @Sendable (Item) -> LibrarySortKeys
    ) -> some View {
        modifier(LibraryPagerLoader(pager: pager, query: query, order: order, key: key, server: server, keys: keys))
    }
}

// MARK: - Sort keys

extension LibrarySortKeys {
    nonisolated init(album: Album) {
        self.init(
            title: album.title,
            artist: album.artistName,
            added: album.libraryAddedDate ?? LibraryDemo.added(album.id),
            played: album.lastPlayedDate ?? LibraryDemo.played(album.id),
            released: album.releaseDate
        )
    }

    nonisolated init(playlist: Playlist) {
        self.init(
            title: playlist.name,
            artist: playlist.curatorName ?? "",
            added: playlist.libraryAddedDate ?? LibraryDemo.added(playlist.id),
            played: playlist.lastPlayedDate ?? LibraryDemo.played(playlist.id),
            released: playlist.lastModifiedDate
        )
    }

    nonisolated init(artist: Artist) {
        self.init(title: artist.name)
    }

    nonisolated init(song: Song, plays: Int) {
        self.init(
            title: song.title,
            artist: song.artistName,
            album: song.albumTitle ?? "",
            added: song.libraryAddedDate ?? LibraryDemo.added(song.id),
            played: song.lastPlayedDate ?? LibraryDemo.played(song.id),
            released: song.releaseDate,
            duration: song.duration ?? 0,
            plays: plays
        )
    }
}

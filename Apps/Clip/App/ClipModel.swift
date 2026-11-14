import Foundation
import Observation
import TracksCore

/// The App Clip's one job: the SharePlay whose code opened it, and a search to pick songs.
@MainActor
@Observable
final class ClipModel {
    /// The SharePlay joined, once a code has opened the App Clip.
    private(set) var session: SharePlayCodeGuest?
    /// Opened without a code: from the App Clips list, or a link without one.
    private(set) var hasNoCode = false

    /// The App Store's banner for Tracks is up, at the bottom.
    var offersTracks = false

    var query = ""
    private(set) var results: [SharePlaySong] = []
    private(set) var searchState: SearchState = .idle

    enum SearchState: Equatable { case idle, loading, loaded, failed }

    private let relay = SharePlayRelayConfig.main

    #if DEBUG
    init() {
        // `-TracksClipDemo`: a pretend session with sample songs, for screenshots.
        if let scene = UserDefaults.standard.string(forKey: "TracksClipDemo") { ClipDemo.start(scene, in: self) }
        // `-TracksClipURL`: opens with a code's link, as an invocation does, where Xcode's
        // `_XCAppClipURL` doesn't reach (a simulator launched from the command line).
        if let link = UserDefaults.standard.string(forKey: "TracksClipURL") { open(URL(string: link)) }
    }
    #endif

    /// Joins the SharePlay a link's code is for. Another code replaces the one before.
    func open(_ url: URL?) {
        guard let url, let invite = SharePlayInvite(url: url) else {
            if session == nil { hasNoCode = true }
            return
        }
        hasNoCode = false
        guard invite != session?.invite || session?.guest.phase == .ended else { return }
        session?.stop()
        let session = SharePlayCodeGuest(invite: invite, relay: relay, looksNearby: false)
        self.session = session
        results = []
        query = ""
        session.start()
    }

    func resume() {
        session?.resume()
    }

    func add(_ song: SharePlaySong, placement: SharePlayPlacement) {
        #if DEBUG
        if ClipDemo.isOn, let session {
            ClipDemo.add(song, placement: placement, in: session)
            return
        }
        #endif
        session?.add(song, placement: placement)
    }

    // MARK: - Searching

    /// The response read off the main actor, which is drawing the field as it's typed in.
    @concurrent
    private nonisolated static func songs(from data: Data, allowsExplicit: Bool) async -> [SharePlaySong] {
        SharePlaySongSearch.songs(from: data, allowsExplicit: allowsExplicit)
    }

    /// Searches after a short pause, so typing doesn't search on every letter.
    func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else {
            results = []
            searchState = .idle
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        searchState = .loading
        #if DEBUG
        if ClipDemo.isOn {
            results = ClipDemo.search(term)
            searchState = .loaded
            return
        }
        #endif
        let storefront = SharePlaySongSearch.storefront(region: Locale.current.region?.identifier)
        guard let url = SharePlaySongSearch.url(for: term, storefront: storefront) else {
            searchState = .failed
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            let allowsExplicit = session?.guest.snapshot?.allowsExplicit ?? true
            let found = await Self.songs(from: data, allowsExplicit: allowsExplicit)
            guard !Task.isCancelled else { return }
            results = found
            searchState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            searchState = .failed
        }
    }
}

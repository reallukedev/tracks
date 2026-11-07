import SwiftUI
import MusicKit
import TracksCore

/// A shelf's title with an action at its trailing edge, as Music's are.
struct ShelfHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        // At accessibility sizes the link goes under the title rather than breaking it.
        AdaptiveStack(verticalAlignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
                .font(.subheadline)
        }
    }
}

/// "Find More", into one of the finders.
struct FindMoreLink: View {
    let route: PlayRoute

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 3) {
                Text("Find More")
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }
}

// MARK: - Songs

/// A suggested song in a list: its cover, name and artist, why it's here, and a way to keep it.
struct SuggestionRow: View {
    let suggestion: Suggestion
    var showsReason = true
    let play: () -> Void

    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @ScaledMetric(relativeTo: .body) private var coverSide: CGFloat = Self.cover
    /// Tapped while it was still being looked for: waiting to play it once it's found.
    @State private var isWaiting = false
    @State private var isHovered = false

    var body: some View {
        let song = suggestion.song
        // With your own music, a suggestion plays only if it's in it; the rest say why not. One
        // still being looked for isn't held against it: a tap waits for the answer.
        let availability = model.musicSource == .yourMusic ? music.availability(title: song.title, artist: song.artistName) : nil
        let isBlocked = availability.map { $0 != .checking && $0.track == nil } ?? false
        HStack(spacing: 12) {
            Button {
                if availability == .checking { isWaiting = true }
                Task {
                    await SuggestionPlayback.play(song, source: model.musicSource, music: music, player: player, play: play)
                    isWaiting = false
                }
            } label: {
                HStack(spacing: 12) {
                    CoverImage(cover: song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: song.albumTitle ?? song.title), size: min(coverSide, 72))
                        .overlay {
                            if isHovered, !isCurrent, !isBlocked {
                                // Music's play glyph on the cover under the pointer.
                                RoundedRectangle(cornerRadius: CoverImage.radius(for: min(coverSide, 72)), style: .continuous)
                                    .fill(.black.opacity(0.4))
                                Image(systemName: "play.fill")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                            if isCurrent {
                                RoundedRectangle(cornerRadius: CoverImage.radius(for: min(coverSide, 72)), style: .continuous)
                                    .fill(.black.opacity(0.4))
                                PlayingWaveform(isActive: player.isPlaying, color: .white)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(song.title)
                                .font(.body)
                                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                                .lineLimit(1)
                            if song.isExplicit { ExplicitBadge() }
                        }
                        Text(song.artistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if showsReason {
                            HStack(spacing: 4) {
                                Image(systemName: suggestion.reason.symbol)
                                    .imageScale(.small)
                                Text(suggestion.reason.rowLine(for: song))
                                    .lineLimit(1)
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer(minLength: 0)
                }
                .opacity(isBlocked ? 0.45 : 1)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(isBlocked ? (availability?.message ?? "") : String(localized: "Plays this song"))

            if isWaiting {
                ProgressView()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Finding This Song")
            } else if let availability {
                AvailabilityAccessory(availability: availability, title: song.title, artist: song.artistName)
            } else {
                FavoriteButton(song: song)
            }
        }
        .padding(.vertical, 6)
        #if os(macOS)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(isHovered ? 0.06 : 0))
        }
        .padding(.horizontal, -6)
        .onHover { hovering in
            withAnimation(PlayMotion.hover) { isHovered = hovering }
        }
        #endif
        .animation(.snappy, value: isBlocked)
        // Looked up again whenever answers may have changed, keeping the last one meanwhile.
        .task(id: "\(suggestion.id.rawValue).\(music.availabilityGeneration)") {
            guard model.musicSource == .yourMusic else { return }
            await music.check(title: song.title, artist: song.artistName, album: song.albumTitle)
        }
    }

    private var isCurrent: Bool {
        player.current?.songIdentity == suggestion.identity
    }

    #if os(macOS)
    static let cover: CGFloat = 40
    /// A row of the suggestions shelf, its cover and two lines.
    static let rowHeight: CGFloat = 56
    #else
    static let cover: CGFloat = 52
    static let rowHeight: CGFloat = 64
    #endif
}

/// The star from Music: favorites a suggested song in Apple Music, which keeps it in the
/// library too. Tapped again, it comes off.
struct FavoriteButton: View {
    let song: Song
    @Environment(PlayerModel.self) private var player
    /// Counts stars given here, so the tap is felt but a lookup finding one isn't.
    @State private var starred = 0

    var body: some View {
        let isFavorite = player.isFavorite(song)
        Button {
            if !isFavorite { starred += 1 }
            player.setFavorite(song, !isFavorite)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isFavorite ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: starred)
        .accessibilityLabel(isFavorite ? "Undo Favorite" : "Favorite")
        .task(id: song.id) { player.lookUpFavorite(song) }
    }
}

/// Favorite or Undo Favorite, for a song's menu, as Music has.
struct FavoriteMenuItem: View {
    let song: Song
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let isFavorite = player.isFavorite(song)
        Button(isFavorite ? "Undo Favorite" : "Favorite", systemImage: isFavorite ? "star.slash" : "star") {
            player.setFavorite(song, !isFavorite)
        }
        .task(id: song.id) { player.lookUpFavorite(song) }
    }
}

/// A suggested song's menu: the usual song actions, and Not Interested in place of Suggest Less.
/// With your own music: what can be done with it there, and in Lidarr.
struct SuggestionMenu: View {
    let suggestion: Suggestion
    /// Not Interested, where the page offers it undoably; otherwise it's taken out here.
    var notInterested: (() -> Void)?
    @Environment(Discovery.self) private var discovery
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.musicSource == .yourMusic {
            YourMusicSongMenu(song: suggestion.song, showsBlock: false)
            Divider()
        } else {
            SongMenu(song: suggestion.song, showsSuggestLess: false)
        }
        Button("Not Interested", systemImage: "hand.thumbsdown") {
            if let notInterested {
                notInterested()
            } else {
                withAnimation(PlayMotion.row) { discovery.dismiss(suggestion) }
            }
        }
        // The stronger no, after the gentler one.
        BlockArtistButton(songBy: suggestion.song.artistName)
    }
}

/// Playing a suggested song. With your own music it plays only if it's there: one still being
/// looked for is looked up first, and one that isn't there says why instead.
@MainActor
enum SuggestionPlayback {
    static func play(_ song: Song, source: MusicSource, music: YourMusic, player: PlayerModel, play: () -> Void) async {
        guard source == .yourMusic else {
            play()
            return
        }
        var availability = music.availability(title: song.title, artist: song.artistName)
        if availability == .checking {
            await music.check(title: song.title, artist: song.artistName, album: song.albumTitle)
            availability = music.availability(title: song.title, artist: song.artistName)
        }
        if availability.track != nil {
            play()
        } else if let message = availability.message {
            player.confirm(message)
        }
    }
}

extension SuggestionReason {
    /// Why a song is here, beside its artist's name: "More from Nova Harbor" under Nova Harbor
    /// would say the name twice, so a song of an artist you play just says so.
    func rowLine(for song: Song) -> String {
        switch self {
        case .moreFrom(let artist) where StatsCalculator.folded(artist) == StatsCalculator.folded(song.artistName):
            String(localized: "By an artist you play")
        case .newRelease(let artist) where StatsCalculator.folded(artist) == StatsCalculator.folded(song.artistName):
            String(localized: "New release")
        default:
            line
        }
    }
}

extension Array where Element == Suggestion {
    /// The suggestions to show. With your own music, only ones known to be there to play, or
    /// with Everything, to be coming from Lidarr: a row appears once it's answered, so lists
    /// only ever grow and a row never shows and then vanishes under a finger.
    @MainActor
    func visible(in music: YourMusic, source: MusicSource, mode: SuggestionMode) -> [Suggestion] {
        guard source == .yourMusic else { return self }
        return filter {
            let availability = music.availability(title: $0.song.title, artist: $0.song.artistName)
            switch mode {
            case .onlyYours: return availability != .checking && availability.isYours
            case .everything, .off: return availability != .checking && availability != .unavailable
            }
        }
    }

    /// How many are still being looked for, with your own music: while there are some, a list
    /// holds its place with loading rows rather than saying there's nothing.
    @MainActor
    func unanswered(in music: YourMusic, source: MusicSource) -> Int {
        guard source == .yourMusic else { return 0 }
        return count { music.availability(title: $0.song.title, artist: $0.song.artistName) == .checking }
    }

    /// Looks up the next of them not yet answered, in order, since only answered rows are
    /// shown, and rows are what look songs up otherwise. Call again as answers come in to
    /// work down the list.
    @MainActor
    func lookUp(in music: YourMusic, source: MusicSource, mode: SuggestionMode, first count: Int = 40) async {
        guard source == .yourMusic, mode != .off else { return }
        let next = filter { music.availability(title: $0.song.title, artist: $0.song.artistName) == .checking }.prefix(count)
        await music.check(next.map { ($0.song.title, $0.song.artistName, $0.song.albumTitle) })
    }
}

/// How a paged shelf of songs lays out: columns of four, as Music lays out songs on a shelf,
/// a page of them at a time. While more can come the shelf shows only whole columns, holding
/// back a short last one until it fills, so its end is never a column of gaps; at the true
/// end a short column is fine, and nothing follows it.
enum SuggestionShelfPaging {
    static let rowsPerColumn = 4

    /// Loading columns enough to fill the widest page, with the next one peeking in on iPhone.
    #if os(macOS)
    static let loadingColumns = 4
    #else
    static let loadingColumns = 2
    #endif

    /// Most of the width on iPhone, so the next column peeks in. On the Mac, as many to a page
    /// as leave each one room for a title without stretching it across the window: three in a
    /// wide window, four in an ultra-wide one, as Music's Top Songs are.
    static func columnWidth(in length: CGFloat) -> CGFloat {
        #if os(macOS)
        // The length is the scroll view's, less its content margins already.
        let columns: CGFloat = length >= 1400 ? 4 : length >= 840 ? 3 : length >= 500 ? 2 : 1
        return (length - PlayMetrics.shelfSpacing * (columns - 1)) / columns
        #else
        return length * 0.9
        #endif
    }

    /// The items in columns, only whole ones while `goesOn`.
    static func columns<Item: Identifiable>(of items: [Item], goesOn: Bool) -> [SuggestionColumn<Item>] {
        let count = goesOn ? items.count / rowsPerColumn * rowsPerColumn : items.count
        return stride(from: 0, to: count, by: rowsPerColumn).map {
            SuggestionColumn(items: Array(items[$0..<min($0 + rowsPerColumn, count)]))
        }
    }
}

/// One column of a paged song shelf, known by its first song, so it keeps its identity as the
/// shelf grows after it.
struct SuggestionColumn<Item: Identifiable>: Identifiable {
    let items: [Item]
    var id: Item.ID { items[0].id }
}

/// Suggested Songs, at the top of Play: Tracks Radio first, then songs you've never played in
/// columns of four. It never ends: as its last column comes into view it opens up another
/// page, and walks further out for more when those run out.
struct SuggestedSongsSection: View {
    /// Off where Tracks Radio has a card of its own above.
    var includesRadio = true
    @Environment(Discovery.self) private var discovery
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @AppStorage(PlayPreferences.tracksRadioKey) private var isRadioOn = true
    @AppStorage(SuggestionMode.storageKey) private var mode = SuggestionMode.everything
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = SuggestionRow.rowHeight
    /// The columns on screen. Only while the last is among them does the shelf open up more, so
    /// songs are only looked up, and your server only asked, as far as you've scrolled.
    @State private var columnsInView: [MusicItemID] = []

    /// Suggestions looked up past the shelf's reach, so the next page is ready as it's reached.
    /// Keep Exploring looks up the rest, as far as you scroll.
    static let lookAhead = 24

    var body: some View {
        let visible = discovery.songs.visible(in: music, source: model.musicSource, mode: mode)
        let reach = discovery.shelfReach
        let songs = Array(visible.prefix(reach))
        let ahead = Array(discovery.songs.prefix(reach + Self.lookAhead))
        let unanswered = ahead.unanswered(in: music, source: model.musicSource)
        let isLoading = !discovery.hasSeeded || (songs.isEmpty && discovery.isExpanding)
        let showsRadio = includesRadio && isRadioOn
        // More to come: songs past the reach, ones still being answered, or further to walk.
        let hasMore = visible.count > reach || unanswered > 0 || discovery.canExpand
        let columns = SuggestionShelfPaging.columns(of: songs, goesOn: hasMore)
        // A column of loading rows only while there's nothing else to show and some is coming.
        let showsLoading = columns.isEmpty && (isLoading || hasMore)
        let isEndInView = showsLoading || columns.last.map { columnsInView.contains($0.id) } ?? false
        if showsRadio || !songs.isEmpty || isLoading || unanswered > 0 {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: String(localized: "Suggested Songs")) {
                    if !songs.isEmpty { FindMoreLink(route: .songFinder(.forYou)) }
                }
                .padding(.horizontal, PlayMetrics.margin)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: PlayMetrics.shelfSpacing) {
                        if showsRadio {
                            TracksRadioTile(side: rowHeight * CGFloat(SuggestionShelfPaging.rowsPerColumn))
                        }
                        ForEach(columns) { column in
                            VStack(spacing: 0) {
                                ForEach(column.items) { suggestion in
                                    row(suggestion, in: visible)
                                    if suggestion.id != column.items.last?.id {
                                        Divider().padding(.leading, 60)
                                    }
                                }
                            }
                            .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                                SuggestionShelfPaging.columnWidth(in: length)
                            }
                        }
                        if showsLoading {
                            // As many columns as the songs will fill, so they arrive in place.
                            ForEach(0..<SuggestionShelfPaging.loadingColumns, id: \.self) { _ in
                                LoadingRows(count: SuggestionShelfPaging.rowsPerColumn)
                                    .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                                        SuggestionShelfPaging.columnWidth(in: length)
                                    }
                            }
                            .transition(.opacity)
                        }
                    }
                    .scrollTargetLayout()
                    .animation(PlayMotion.row, value: columns.map(\.id))
                }
                .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                #if os(macOS)
                // A column past the page's edge fades into the margin, rather than being cut
                // off there: the shelf plainly goes on, and nothing reads as left over.
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(0), .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: PlayMetrics.margin)
                        Color.black
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: PlayMetrics.margin)
                    }
                }
                #endif
                // Half in view counts, so a column peeking in at the edge doesn't.
                .onScrollTargetVisibilityChange(idType: MusicItemID.self, threshold: 0.5) { columnsInView = $0 }
            }
            // Again as each answer comes in, and each time the end comes into view.
            .task(id: "\(isEndInView).\(reach).\(discovery.songs.count).\(discovery.expansions).\(music.availabilityGeneration).\(mode.rawValue).\(unanswered).\(visible.count)") {
                if isEndInView, visible.count > reach {
                    // Songs are ready past the end: open up the next page of them.
                    discovery.shelfReach += Discovery.shelfPage
                } else if unanswered > 0 {
                    await ahead.lookUp(in: music, source: model.musicSource, mode: mode, first: ahead.count)
                } else if isEndInView, discovery.canExpand {
                    await discovery.expand()
                }
            }
        }
    }

    /// Plays from the song, through the ones the shelf shows: not those it leaves out.
    private func row(_ suggestion: Suggestion, in visible: [Suggestion]) -> some View {
        SuggestionRow(suggestion: suggestion, showsReason: false) {
            let all = visible.map(\.song)
            let start = all.firstIndex(of: suggestion.song) ?? 0
            player.play(.songs(all, startingAt: start), from: .songs(String(localized: "Suggested Songs")))
        }
        .frame(height: rowHeight)
        .contextMenu { SuggestionMenu(suggestion: suggestion) }
    }
}

/// Keep Exploring, at the very end of Play: suggested songs for as long as you scroll.
struct KeepExploringSection: View {
    /// Whether the Suggested Songs shelf is above, which this carries on from.
    var followsShelf = true
    @Environment(Discovery.self) private var discovery
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @AppStorage(SuggestionMode.storageKey) private var mode = SuggestionMode.everything
    /// Whether the end of the list is on screen: only then does it look for more, so songs
    /// are only looked up, and your server only asked, as far as you've scrolled.
    @State private var isEndInView = false

    var body: some View {
        let visible = discovery.songs.visible(in: music, source: model.musicSource, mode: mode)
        let songs = Array(visible.dropFirst(followsShelf ? discovery.shelfReach : 0))
        // The shelf above looks up its own; this goes on from there.
        let rest = Array(discovery.songs.dropFirst(followsShelf ? discovery.shelfReach + SuggestedSongsSection.lookAhead : 0))
        let unanswered = rest.unanswered(in: music, source: model.musicSource)
        if !songs.isEmpty || discovery.canExpand && discovery.hasSeeded && !discovery.songs.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("Keep Exploring")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 8)

                ForEach(songs) { suggestion in
                    SuggestionRow(suggestion: suggestion) {
                        let all = visible.map(\.song)
                        let start = all.firstIndex(of: suggestion.song) ?? 0
                        player.play(.songs(all, startingAt: start), from: .songs(String(localized: "Suggested Songs")))
                    }
                    .contextMenu { SuggestionMenu(suggestion: suggestion) }
                    Divider().padding(.leading, 64)
                }

                if unanswered == 0, discovery.canExpand, discovery.expandFailed {
                    LoadMoreFailedRow(text: "Couldn't load more suggestions.") {
                        Task { await discovery.expand() }
                    }
                } else if unanswered > 0 || discovery.canExpand {
                    // The end of the list: while it's on screen, the next songs are looked up,
                    // and once they're answered, more are asked for.
                    LoadingRows(count: 2)
                        .onScrollVisibilityChange(threshold: 0.1) { isEndInView = $0 }
                        .onDisappear { isEndInView = false }
                } else {
                    Label("That's everything for now. Play some of these, and there'll be more.", systemImage: "sparkles")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
            // Again as each batch is answered, working down the list a dozen at a time, and
            // only while the end is in view.
            .task(id: "\(isEndInView).\(discovery.songs.count).\(discovery.shelfReach).\(music.availabilityGeneration).\(mode.rawValue).\(unanswered)") {
                guard isEndInView else { return }
                if unanswered > 0 {
                    await rest.lookUp(in: music, source: model.musicSource, mode: mode, first: 12)
                } else if discovery.canExpand {
                    await discovery.expand()
                }
            }
            .animation(.snappy, value: songs.count)
        }
    }
}

// MARK: - Artists

/// Suggested Artists, near the top of Play. Like Suggested Songs, it never ends: scrolled to
/// its end, it walks further out from your artists for more.
struct SuggestedArtistsShelf: View {
    @Environment(Discovery.self) private var discovery
    /// Whether the loading tile at the end is on screen: only then does it walk further.
    @State private var isEndInView = false

    var body: some View {
        if !discovery.artists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfHeader(title: String(localized: "Suggested Artists")) {
                    FindMoreLink(route: .artistFinder)
                }
                .padding(.horizontal, PlayMetrics.margin)

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: PlayMetrics.shelfSpacing) {
                        ForEach(discovery.artists) { artist in
                            SuggestedArtistTile(suggestion: artist)
                        }
                        if discovery.canExpand, discovery.expandFailed {
                            RetryArtistTile { Task { await discovery.expand() } }
                        } else if discovery.canExpand {
                            LoadingArtistTile()
                                .onScrollVisibilityChange(threshold: 0.1) { isEndInView = $0 }
                                .onDisappear { isEndInView = false }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
            // Again after each step out, even one that found no one new, while the end is in
            // view. A step that couldn't reach Apple Music doesn't count, so it doesn't loop.
            .task(id: "\(isEndInView).\(discovery.expansions)") {
                guard isEndInView else { return }
                await discovery.expand()
            }
        }
    }
}

/// At the end of the shelf in place of the loading tile, when Apple Music couldn't be reached.
private struct RetryArtistTile: View {
    let retry: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 120

    var body: some View {
        let side = min(side, 180)
        Button(action: retry) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: side, height: side)
                    .background(Color(.secondarySystemFill), in: .circle)
                Text("Try Again")
                    .font(.subheadline.weight(.medium))
            }
            .frame(width: side)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Couldn't load more artists. Try Again"))
    }
}

/// A suggested artist's shape, at the end of the shelf while more are found.
private struct LoadingArtistTile: View {
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 120

    var body: some View {
        let side = min(side, 180)
        VStack(spacing: 8) {
            Circle()
                .fill(Color(.secondarySystemFill))
                .frame(width: side, height: side)
            VStack(spacing: 6) {
                Capsule().fill(Color(.secondarySystemFill)).frame(width: side * 0.6, height: 10)
                Capsule().fill(Color(.tertiarySystemFill)).frame(width: side * 0.4, height: 9)
            }
        }
        .frame(width: side)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }
}

/// An artist you've never played: a circle, a name, and which of yours they're like.
struct SuggestedArtistTile: View {
    let suggestion: SuggestedArtist
    @Environment(Discovery.self) private var discovery
    @Environment(PlayerModel.self) private var player
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 120

    var body: some View {
        let side = min(side, 180)
        NavigationLink(value: PlayRoute.artist(suggestion.artist)) {
            VStack(spacing: 8) {
                CoverImage(cover: suggestion.artist.artwork.map(CoverArt.artwork) ?? .url(nil, seed: suggestion.artist.name), size: side, isCircle: true)
                VStack(spacing: 1) {
                    Text(suggestion.artist.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(suggestion.shortLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: side)
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.pressable)
        .contextMenu { SuggestedArtistMenu(suggestion: suggestion) }
    }
}

/// What can be done with a suggested artist from a long press.
struct SuggestedArtistMenu: View {
    let suggestion: SuggestedArtist
    @Environment(Discovery.self) private var discovery
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model

    var body: some View {
        // Apple Music's; with your own music, the artist's page shows what you have of theirs.
        if !player.isDemo, model.musicSource == .appleMusic {
            Button("Play Top Songs", systemImage: "play") {
                Task { await ArtistPlayback.playTopSongs(of: suggestion.artist, player: player) }
            }
            Button("Create Station", systemImage: "dot.radiowaves.left.and.right") {
                player.playStation(from: suggestion.artist)
            }
            Divider()
        }
        AddToLidarrButton(artistName: suggestion.artist.name)
        Button("Not Interested", systemImage: "hand.thumbsdown") {
            withAnimation { discovery.hide(suggestion) }
        }
        BlockArtistButton(artist: suggestion.artist.name)
    }
}

/// Playing an artist straight from a tile, without opening their page.
@MainActor
enum ArtistPlayback {
    static func playTopSongs(of artist: Artist, player: PlayerModel) async {
        let songs = if let known = artist.topSongs { Array(known) } else { (try? await artist.with([.topSongs]).topSongs).map(Array.init) ?? [] }
        let playable = PlayPreferences.versions(of: songs)
        guard !playable.isEmpty else {
            player.problem = .nothingToPlay
            return
        }
        await player.start(.songs(playable), from: PlayContext(kind: .artist, title: artist.name))
    }
}

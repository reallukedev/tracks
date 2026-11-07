import SwiftUI
import MusicKit
import TracksCore

// MARK: - Page header

/// A library page's title in the content, with one fact under it and Play and Shuffle
/// trailing, as Music's library pages are on the Mac. The table or grid starts under it.
struct LibraryPageHeader: View {
    let title: String
    /// One fact: "2,431 songs". Nil while it's still being counted.
    let subtitle: String?
    var play: (() -> Void)?
    var shuffle: (() -> Void)?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                // A space while counting, so the page doesn't shift when the count arrives.
                Text(subtitle ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 16)
            if play != nil || shuffle != nil {
                LibraryPlayButtons(play: play, shuffle: shuffle)
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

/// Play and Shuffle for everything on a library page: on the Mac a prominent and a bordered
/// button; on iPhone a pair of capsules across the top of the list, as Music's are.
struct LibraryPlayButtons: View {
    var play: (() -> Void)?
    var shuffle: (() -> Void)?
    @State private var taps = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(macOS)
        HStack(spacing: 8) {
            if let play {
                Button("Play", systemImage: "play.fill", action: play)
                    .buttonStyle(.glassProminent)
            }
            if let shuffle {
                Button("Shuffle", systemImage: "shuffle", action: shuffle)
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.regular)
        #else
        // Side by side, or one above the other at the largest text sizes, where two capsules
        // across the width would break their labels.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if let play {
                Button {
                    taps += 1
                    play()
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
            }
            if let shuffle {
                Button {
                    taps += 1
                    shuffle()
                } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
            }
        }
        .font(.headline)
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        #endif
    }
}

// MARK: - Tiles

/// A cover in a library grid: the cover, its name and a line under it. On the Mac it lifts a
/// little under the pointer and shows Music's two round buttons over its foot, Play on the left
/// and More on the right; a click anywhere else opens it.
struct LibraryCoverTile<Cover: View, Menu: View>: View {
    let title: String
    let subtitle: String?
    let route: PlayRoute
    var play: (() -> Void)?
    /// A fixed side for a shelf; nil fills the grid's column.
    var side: CGFloat?
    /// The cover at a side, or filling its cell when the side is nil.
    @ViewBuilder var cover: (CGFloat?) -> Cover
    @ViewBuilder var menu: Menu

    #if os(macOS)
    @State private var isHovered = false
    #endif

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: LibraryTileMetrics.coverGap) {
                cover(side)
                    .frame(width: side, height: side)
                    #if os(macOS)
                    .scaleEffect(isHovered ? 1.02 : 1)
                    .shadow(color: .black.opacity(isHovered ? 0.18 : 0), radius: 10, y: 5)
                    #endif
                LibraryTileText(title: title, subtitle: subtitle)
            }
            .frame(width: side, alignment: .leading)
            .contentShape(.rect)
            .accessibilityElement(children: .combine)
        }
        #if os(macOS)
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            // Over the cover's foot: a square as wide as the tile, the cover's place.
            if isHovered {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .scaleEffect(1.02)
                    .overlay(alignment: .bottom) {
                        HStack {
                            if let play {
                                LibraryHoverPlayButton(action: play)
                            }
                            Spacer(minLength: 0)
                            LibraryHoverMoreButton { menu }
                        }
                        .padding(10)
                    }
                    .transition(.opacity)
            }
        }
        .onHover { hovering in withAnimation(PlayMotion.hover) { isHovered = hovering } }
        .help(title)
        #else
        .buttonStyle(.pressable)
        #endif
        .contextMenu { menu }
    }

    #if os(macOS)
    /// A tile's side on a shelf.
    static var shelfSide: CGFloat { 176 }
    #endif
}

/// A tile's name and the line under it, one line each.
struct LibraryTileText: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LibraryTileMetrics.lineGap) {
            Text(title)
                .foregroundStyle(.primary)
                .lineLimit(1)
            // A subtitle's line even when there's none, so a row of tiles lines up.
            Text(subtitle ?? " ")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(LibraryTileMetrics.font)
    }
}

/// The measures a tile and its placeholder share, so one takes the other's place exactly.
enum LibraryTileMetrics {
    #if os(macOS)
    static let font = Font.callout
    #else
    static let font = Font.subheadline
    #endif
    static let coverGap: CGFloat = 7
    static let lineGap: CGFloat = 1
}

#if os(macOS)
/// Music's round Play over a cover under the pointer.
struct LibraryHoverPlayButton: View {
    static let side: CGFloat = 32
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.side, height: Self.side)
                .background(.black.opacity(isHovered ? 0.7 : 0.5), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Play")
        .accessibilityLabel("Play")
    }
}

/// Music's round More over a cover under the pointer: the cover's own menu.
struct LibraryHoverMoreButton<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var isHovered = false

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: LibraryHoverPlayButton.side, height: LibraryHoverPlayButton.side)
                .background(.black.opacity(isHovered ? 0.7 : 0.5), in: .circle)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("More")
        .accessibilityLabel("More")
    }
}
#endif

/// The grid the covers stand in: covers in as many columns as fit on the Mac, two columns of
/// the width on iPhone (one at the largest text sizes).
struct LibraryGrid<Content: View>: View {
    /// The page's margin, or none inside something that has its own.
    var margin = PlayMetrics.margin
    @ViewBuilder var content: Content
    @ScaledMetric(relativeTo: .subheadline) private var minimum: CGFloat = 150

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: rowSpacing) {
            content
        }
        .padding(.horizontal, margin)
    }

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 164, maximum: 210), spacing: 20, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: min(minimum, 320)), spacing: 16, alignment: .top)]
        #endif
    }

    private var rowSpacing: CGFloat {
        #if os(macOS)
        26
        #else
        22
        #endif
    }
}

// MARK: - Placeholders

/// A grid's shape while it loads: plain squares where the covers go and bars where their names
/// will be, in the same grid and the same line heights, so nothing moves when they arrive.
struct LibraryGridPlaceholder: View {
    /// Enough to fill a wide window; the rest are clipped below the fold.
    var count = 18
    /// Round, for artists.
    var isCircle = false
    var margin = PlayMetrics.margin

    var body: some View {
        LibraryGrid(margin: margin) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: LibraryTileMetrics.coverGap) {
                    Group {
                        if isCircle {
                            Circle().fill(Color.placeholderFill)
                        } else {
                            RoundedRectangle(cornerRadius: CoverImage.maximumRadius, style: .continuous)
                                .fill(Color.placeholderFill)
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    LibraryTileText(title: Self.titles[index % Self.titles.count], subtitle: Self.subtitles[index % Self.subtitles.count])
                        .redacted(reason: .placeholder)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    /// Stand-in names of different lengths, drawn as bars.
    private static let titles = ["Placeholder", "Album Name", "A Longer Title", "Record", "Name Here", "Title"]
    private static let subtitles = ["Artist", "Artist Name", "Someone", "An Artist", "Band", "Name"]
}

/// Rows of artists while they load: a circle and a name's bar.
struct LibraryArtistRowsPlaceholder: View {
    var count = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                LibraryArtistRow(name: Self.names[index % Self.names.count], picture: nil, showsPicture: false)
                    .redacted(reason: .placeholder)
                    .padding(.vertical, LibraryArtistRow.verticalPadding)
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    private static let names = ["Artist Name", "Someone", "A Longer Name", "Band", "The Artist", "Name Here"]
}

/// An artist in a library list: their picture in a circle and their name.
struct LibraryArtistRow: View {
    let name: String
    let picture: CoverArt?
    var detail: String?
    var plays: Int?
    /// Off for a placeholder, which draws a plain circle.
    var showsPicture = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Self.spacing) {
            if showsPicture {
                ArtistPicture(cover: picture, name: name, size: Self.side)
            } else {
                Circle()
                    .fill(Color.placeholderFill)
                    .frame(width: Self.side, height: Self.side)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .lineLimit(isLarge ? 3 : 1)
                // At the largest sizes the plays go under the name, which needs the width.
                if let facts {
                    Text(facts)
                        .font(Self.detailFont)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(isLarge ? 2 : 1)
                }
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: Self.minimumHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The line under the name, where there's something to say. Your plays of an artist
    /// live on their stats page, not on a row of a list.
    private var facts: String? { detail }

    #if os(macOS)
    static let side: CGFloat = 32
    private static let spacing: CGFloat = 10
    private static let minimumHeight: CGFloat = 40
    private static let detailFont = Font.callout
    static let verticalPadding: CGFloat = 2
    #else
    static let side: CGFloat = 48
    private static let spacing: CGFloat = 12
    private static let minimumHeight: CGFloat = 48
    private static let detailFont = Font.subheadline
    static let verticalPadding: CGFloat = 8
    #endif
}

extension View {
    /// A library artist row's insets: on the Mac, the page's leading edge and no separators,
    /// as Music's artist list has; the system's on iPhone.
    func libraryArtistRowInsets() -> some View {
        #if os(macOS)
        listRowInsets(EdgeInsets(top: 2, leading: PlayMetrics.margin - 8, bottom: 2, trailing: PlayMetrics.margin - 8))
            .listRowSeparator(.hidden)
        #else
        alignmentGuide(.listRowSeparatorLeading) { _ in 60 }
            .libraryRowInsets()
        #endif
    }

    /// Music's library rows: 8 points above and below, not the 15 a list gives by default.
    func libraryRowInsets() -> some View {
        listRowInsets(.vertical, 8)
    }
}

// MARK: - Hover

extension View {
    /// Lifts a card or cover a little under the pointer on the Mac. Nothing on iPhone.
    func hoverLift() -> some View {
        #if os(macOS)
        modifier(HoverLift())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct HoverLift: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.02 : 1)
            .shadow(color: .black.opacity(isHovered ? 0.16 : 0), radius: 10, y: 5)
            .onHover { hovering in withAnimation(PlayMotion.hover) { isHovered = hovering } }
    }
}
#endif

// MARK: - Your plays by artist

extension View {
    /// Keeps `plays` at every artist's plays in the history, by folded name, read off the main
    /// actor since it walks every play.
    func artistPlays(into plays: Binding<[String: Int]>) -> some View {
        modifier(ArtistPlaysReader(plays: plays))
    }
}

private struct ArtistPlaysReader: ViewModifier {
    @Binding var plays: [String: Int]
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.task(id: model.library.revision) {
            let history = model.library.history
            plays = await OffMainActor.run { ArtistStories.plays(in: history) }
        }
    }
}

// MARK: - States

#if os(iOS)
extension View {
    /// A list page's state (loading, empty, couldn't load, nothing matching) as the one row of
    /// the list its rows will fill. A page's filter field waits under the large title until
    /// it's pulled down, tucked into the page's scroll view. A state standing where the list
    /// will be has no scroll view, so the field showed, then vanished as the list arrived,
    /// on every push into the library; one list from the first frame keeps it tucked away.
    func libraryStateRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
#endif

/// The Apple Music library, or why it can't be shown: no access yet, or access turned off.
/// Sample data never asks Apple Music, so it explains that instead, unless the sample library
/// stands in (`-TracksDemoLibrary YES`).
struct LibraryAccessGate<Content: View>: View {
    /// The page's title, in the content on the Mac, where it isn't in the toolbar.
    var title: String?
    @ViewBuilder var content: Content
    @Environment(AppModel.self) private var model

    var body: some View {
        if isOpen {
            content
        } else {
            ScrollView {
                #if os(macOS)
                if let title {
                    LibraryPageHeader(title: title, subtitle: nil)
                }
                #endif
                VStack(alignment: .leading, spacing: 0) {
                    if model.isShowingSampleData, model.musicAuthorization == .authorized {
                        PlayStateCard(
                            symbol: "music.note.house",
                            title: String(localized: "Your Library Isn't in the Sample"),
                            message: String(localized: "Sample data stands in for your history only. Turn it off in Settings to see your Apple Music library here.")
                        ) { EmptyView() }
                    } else {
                        PlayAccessCard()
                    }
                }
                .libraryStateWidth()
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.vertical, isTitled ? 0 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var isOpen: Bool {
        if LibraryDebugState.current != nil || LibraryDemo.isOn { return true }
        return model.musicAuthorization == .authorized && !model.isShowingSampleData
    }

    private var isTitled: Bool {
        #if os(macOS)
        title != nil
        #else
        false
        #endif
    }
}

/// An empty Apple Music library, in place: what goes here, and a way to find something.
struct LibraryEmptyAppleMusic: View {
    let section: LibrarySection
    @Environment(AppModel.self) private var model

    var body: some View {
        PlayStateCard(
            symbol: section.symbol,
            title: title,
            message: message
        ) {
            Button(browseTitle) {
                #if os(macOS)
                model.sidebarSelection = .listenNow
                #else
                model.playNavigator.path = NavigationPath()
                #endif
            }
            .buttonStyle(.glassProminent)
        }
        .libraryStateWidth()
        .padding(.horizontal, PlayMetrics.margin)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var title: String {
        switch section {
        case .playlists: String(localized: "No Playlists Yet")
        case .albums: String(localized: "No Albums Yet")
        case .artists: String(localized: "No Artists Yet")
        case .songs: String(localized: "No Songs Yet")
        }
    }

    private var message: String {
        switch section {
        case .playlists: String(localized: "Playlists you make or add in Apple Music show here.")
        case .albums, .artists, .songs: String(localized: "Add songs and albums to your Apple Music library from Play or search, and they show here.")
        }
    }

    private var browseTitle: String {
        #if os(macOS)
        String(localized: "Go to Listen Now")
        #else
        String(localized: "Go to Play")
        #endif
    }
}

/// Your Music with nothing in it, in place: import songs, or connect a server.
struct LibraryEmptyYourMusic: View {
    let title: String
    @Environment(YourMusic.self) private var music
    @State private var importsFiles = false
    @State private var addsServer = false

    var body: some View {
        PlayStateCard(
            symbol: "music.note.house",
            title: title,
            message: String(localized: "Import songs from this device, or connect a server with your music on it. Everything you add shows here.")
        ) {
            HStack(spacing: 10) {
                Button("Import Songs", systemImage: "music.note") { importsFiles = true }
                    .buttonStyle(.glassProminent)
                Button("Connect a Server", systemImage: "server.rack") { addsServer = true }
                    .buttonStyle(.glass)
            }
        }
        .libraryStateWidth()
        .padding(.horizontal, PlayMetrics.margin)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(isPresented: $importsFiles, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await music.importItems(urls) }
            }
        }
        .sheet(isPresented: $addsServer) { ServerForm() }
    }
}

/// A library that couldn't be read, in place, with Try Again.
struct LibraryLoadFailed: View {
    let retry: () async -> Void

    var body: some View {
        PlayStateCard(
            symbol: "exclamationmark.triangle",
            title: String(localized: "Couldn't Load Your Library"),
            message: String(localized: "Apple Music didn't answer. Check your connection, and that Tracks can use Apple Music.")
        ) {
            Button("Try Again") { Task { await retry() } }
                .buttonStyle(.glass)
        }
        .libraryStateWidth()
        .padding(.horizontal, PlayMetrics.margin)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Nothing in the library matching the filter.
struct LibraryNoMatches: View {
    let query: String

    var body: some View {
        ContentUnavailableView.search(text: query.trimmingCharacters(in: .whitespaces))
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
    }
}

extension View {
    /// A state card's width: never wider than a paragraph reads well, and never so narrow that
    /// its wrapping text grows tall. The Mac asks a window's content for its smallest size, and
    /// text that wraps at no width at all would push the whole window's content off its top.
    func libraryStateWidth() -> some View {
        frame(minWidth: 280, maxWidth: 560, alignment: .leading)
    }
}

/// A library state forced by `-TracksLibraryState loading|empty|failed`, for screenshots of the
/// states sample data can't reach. Debug builds only.
enum LibraryDebugState: String {
    case loading, empty, failed

    static var current: LibraryDebugState? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "TracksLibraryState").flatMap(LibraryDebugState.init)
        #else
        nil
        #endif
    }
}

#if DEBUG
/// Opens a page over a library page at launch, for screenshots: `-TracksLibraryPush localArtist`
/// (the first artist in your music), `localArtist.longest` (the longest name),
/// `localArtist.missing` (one that's gone), `lidarrArtist`, or `appleSongs`, `appleAlbums`,
/// `appleArtists` and `applePlaylists` (Apple Music's library, which sample data can't reach
/// from Play). `appleOverview` shows ``LibraryOverview`` on a page of its own, as Play will
/// show it, on iPhone. Once per launch. On iPhone, `-TracksPage yourArtists` reaches a page
/// that pushes it.
@MainActor
enum LibraryLaunch {
    private static var hasPushed = false

    /// `-TracksArtistPictures YES`: artists without a picture get a drawn one, to see the
    /// picture header with sample data, which has none.
    static var drawsSamplePictures: Bool { UserDefaults.standard.bool(forKey: "TracksArtistPictures") }

    /// Whether the playlists page stands in for the overview, for `appleOverview`.
    static var showsOverview: Bool { UserDefaults.standard.string(forKey: "TracksLibraryPush") == "appleOverview" }

    static func push(in model: AppModel) {
        guard !hasPushed, let value = UserDefaults.standard.string(forKey: "TracksLibraryPush"),
              let route = route(value, in: model)
        else { return }
        hasPushed = true
        model.playNavigator.show(route)
        walk(in: model)
    }

    private static func route(_ name: some StringProtocol, in model: AppModel) -> PlayRoute? {
        let artists = model.yourMusic.index.artists
        return switch name {
        case "localArtist": artists.first.map { .localArtist($0.id) }
        case "localArtist.longest": artists.max { $0.name.count < $1.name.count }.map { .localArtist($0.id) }
        case "localArtist.missing": .localArtist("missing")
        case "lidarrArtist": model.lidarr.artists.first?.id.map(PlayRoute.lidarrArtist)
        case "appleSongs": .library(.songs)
        case "appleAlbums": .library(.albums)
        case "appleArtists": .library(.artists)
        case "applePlaylists", "appleOverview": .library(.playlists)
        case "appleAlbum": LibraryDemo.items(Album.self)?.first.map(PlayRoute.album)
        case "applePlaylist": LibraryDemo.items(Playlist.self)?.first.map(PlayRoute.playlist)
        case "appleArtist": LibraryDemo.items(Artist.self)?.first.map(PlayRoute.artist)
        default: nil
        }
    }

    /// `-TracksLibrarySteps appleAlbum,back,play`: what to do next, a second and a half apart,
    /// to record moving through the library as taps would: push any page `-TracksLibraryPush`
    /// names, or the sample library's first `appleAlbum`, `applePlaylist` or `appleArtist`; go
    /// `back`; or `play` a mix, which brings in the mini player.
    private static func walk(in model: AppModel) {
        guard let steps = UserDefaults.standard.string(forKey: "TracksLibrarySteps") else { return }
        Task {
            for step in steps.split(separator: ",") {
                try? await Task.sleep(for: .seconds(1.5))
                switch step {
                case "back":
                    if !model.playNavigator.path.isEmpty { model.playNavigator.path.removeLast() }
                case "play":
                    if let mix = model.playFeed.mixes.mixes.first {
                        model.player.play(.history(model.player.songs(in: mix)), from: PlayContext(kind: .mix, title: mix.kind.title))
                    }
                default:
                    if let route = route(step, in: model) { model.playNavigator.show(route) }
                }
            }
        }
    }
}
#endif

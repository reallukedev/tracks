import SwiftUI
import MusicKit
import TracksCore

/// Your Apple Music library's artists. On the Mac, Music's Artists view: the list on the
/// left, the chosen artist's albums on the right. On iPhone, a list with their pictures and
/// Music's A to Z index down the side.
struct LibraryArtistsPage: View {
    let query: String
    /// Artists are gathered whole on both platforms: there are few enough, and the index
    /// needs all of them, in Music's order ("The Beatles" under B).
    @State private var pager = LibraryPager<Artist>(gathers: true)
    @State private var plays: [String: Int] = [:]
    #if os(macOS)
    @State private var albums = LibraryPager<Album>()
    @State private var selection: Artist.ID?
    #endif

    var body: some View {
        content
            .artistPlays(into: $plays)
            .loads(pager, query: query, order: .title) { LibrarySortKeys(artist: $0) }
            #if os(macOS)
            .loads(albums, query: "", order: .natural(.year)) { LibrarySortKeys(album: $0) }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            LibraryPageHeader(title: String(localized: "Artists"), subtitle: pager.count(Self.count))
            LibraryPagerContent(pager: pager, query: query, section: .artists) {
                LibraryArtistSplitPlaceholder()
            } content: {
                LibraryArtistSplit(
                    artists: pager.items,
                    selection: $selection,
                    name: \.name,
                    picture: { $0.artwork.map(CoverArt.artwork) },
                    open: { openPlayRoute(.artist($0)) }
                ) { artist in
                    LibraryAppleArtistDetail(artist: artist, albums: albums(of: artist), plays: plays[StatsCalculator.folded(artist.name)])
                } menu: { artist in
                    LibraryArtistMenu(name: artist.name, artist: artist)
                }
            }
        }
        #else
        LibraryPagerContent(pager: pager, query: query, section: .artists, isList: true) {
            LibraryArtistRowsPlaceholder()
        } content: {
            LibraryArtistIndexSections(artists: pager.items, name: \.name) { artist in
                NavigationLink(value: PlayRoute.artist(artist)) {
                    LibraryArtistRow(
                        name: artist.name,
                        picture: artist.artwork.map(CoverArt.artwork),
                        plays: plays[StatsCalculator.folded(artist.name)]
                    )
                }
                .contextMenu { LibraryArtistMenu(name: artist.name, artist: artist) }
            }
        }
        .listSectionIndexVisibility(.visible)
        #endif
    }

    #if os(macOS)
    @Environment(\.openPlayRoute) private var openPlayRoute

    /// Their albums in your library, newest first.
    private func albums(of artist: Artist) -> [Album] {
        let name = StatsCalculator.folded(artist.name)
        return albums.items.filter { StatsCalculator.folded($0.artistName) == name }
    }
    #endif

    private static func count(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) artist](inflect: true)").characters)
    }
}

#if os(iOS)
/// Artists in one run, as Music lists them, a section per letter for its A to Z index down
/// the trailing edge, which the list shows with `listSectionIndexVisibility(.visible)`. The
/// letters live in the index, not as headers between the rows.
struct LibraryArtistIndexSections<Artist: Identifiable, Row: View>: View {
    let artists: [Artist]
    let name: (Artist) -> String
    @ViewBuilder var row: (Artist) -> Row

    var body: some View {
        ForEach(LibrarySort.sections(artists, name: name)) { section in
            Section {
                ForEach(section.items) { artist in
                    row(artist)
                        // Clear of the index, which runs down the trailing edge.
                        .padding(.trailing, 10)
                        .libraryArtistRowInsets()
                        .navigationLinkIndicatorVisibility(.hidden)
                }
            }
            .sectionIndexLabel(section.letter)
        }
    }
}
#endif

#if os(macOS)
/// Music's Artists view on the Mac: the artists down the left, with their pictures, and the
/// one chosen on the right. Arrow keys move through them; a double-click or Return opens the
/// artist's own page.
struct LibraryArtistSplit<Artist: Identifiable, Detail: View, Menu: View>: View {
    let artists: [Artist]
    @Binding var selection: Artist.ID?
    let name: (Artist) -> String
    let picture: (Artist) -> CoverArt?
    let open: (Artist) -> Void
    @ViewBuilder var detail: (Artist) -> Detail
    @ViewBuilder var menu: (Artist) -> Menu

    static var listWidth: CGFloat { 260 }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(artists) { artist in
                    HStack(spacing: 10) {
                        ArtistPicture(cover: picture(artist), name: name(artist), size: LibraryArtistRow.side)
                        Text(name(artist))
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .listRowSeparator(.hidden)
                    .tag(artist.id)
                    .accessibilityElement(children: .combine)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: Artist.ID.self) { ids in
                if let artist = artists.first(where: { ids.contains($0.id) }) { menu(artist) }
            } primaryAction: { ids in
                if let artist = artists.first(where: { ids.contains($0.id) }) { open(artist) }
            }
            .frame(width: Self.listWidth)
            Divider()
            Group {
                if let chosen {
                    detail(chosen)
                        .id(chosen.id)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: artists.map(\.id), initial: true) { _, ids in
            // The first artist, until one's chosen or the chosen one is filtered away.
            if selection == nil || !ids.contains(where: { $0 == selection }) {
                selection = ids.first
            }
        }
    }

    private var chosen: Artist? {
        artists.first { $0.id == selection }
    }
}

/// The right of the Artists view for an artist in Apple Music: their name, what you have of
/// theirs, Shuffle and their page, then their albums.
private struct LibraryAppleArtistDetail: View {
    let artist: Artist
    let albums: [Album]
    let plays: Int?
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        LibraryArtistDetail(
            name: artist.name,
            picture: artist.artwork.map(CoverArt.artwork),
            facts: facts,
            shuffle: albums.isEmpty ? nil : { shuffle() },
            open: { openPlayRoute(.artist(artist)) }
        ) {
            ForEach(albums) { album in
                LibraryAlbumTile(album: album, showsYear: true)
            }
        }
    }

    /// "3 albums".
    private var facts: String {
        String(AttributedString(localized: "^[\(albums.count) album](inflect: true)").characters)
    }

    /// Their songs in your library, shuffled. The songs are read once for the whole library.
    private func shuffle() {
        Task {
            let songs = LibraryCache.gatherer(for: Song.self)
            await songs.gather()
            let name = StatsCalculator.folded(artist.name)
            let theirs = songs.items.filter { StatsCalculator.folded($0.artistName) == name }
            guard !theirs.isEmpty else { return }
            player.play(.songs(theirs), from: PlayContext(kind: .artist, title: artist.name), shuffled: true)
        }
    }
}

/// The right of the Artists view: the artist's picture and name, one line of facts, Shuffle and
/// their page, then their albums as a grid.
struct LibraryArtistDetail<Albums: View>: View {
    let name: String
    let picture: CoverArt?
    let facts: String
    let shuffle: (() -> Void)?
    let open: () -> Void
    @ViewBuilder var albums: Albums

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 16) {
                    ArtistPicture(cover: picture, name: name, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.title.bold())
                            .lineLimit(2)
                            .accessibilityAddTraits(.isHeader)
                        Text(facts)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        if let shuffle {
                            Button("Shuffle", systemImage: "shuffle", action: shuffle)
                                .buttonStyle(.glassProminent)
                        }
                        Button("Artist Page", systemImage: "music.microphone", action: open)
                            .buttonStyle(.glass)
                            .help("Open \(name)")
                    }
                    .fixedSize()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20, alignment: .top)], alignment: .leading, spacing: 26) {
                    albums
                }
            }
            // A readable width on a wide display, where the buttons would drift far from the name.
            .frame(maxWidth: Self.maximumWidth, alignment: .leading)
            .padding(.horizontal, PlayMetrics.margin)
            .padding(.top, 4)
            .padding(.bottom, PlayMetrics.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static var maximumWidth: CGFloat { 1100 }
}

/// The Artists view's shape while it loads: circles and names on the left, a picture, a name
/// and plain covers on the right.
struct LibraryArtistSplitPlaceholder: View {
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<14, id: \.self) { index in
                    LibraryArtistRow(name: Self.names[index % Self.names.count], picture: nil, showsPicture: false)
                        .redacted(reason: .placeholder)
                        .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 18)
            .frame(width: LibraryArtistSplit<Artist, EmptyView, EmptyView>.listWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            Divider()
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Circle()
                        .fill(Color.placeholderFill)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "Artist Name").font(.title.bold())
                        Text(verbatim: "3 albums").font(.subheadline)
                    }
                    .redacted(reason: .placeholder)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20, alignment: .top)], alignment: .leading, spacing: 26) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: LibraryTileMetrics.coverGap) {
                            RoundedRectangle(cornerRadius: CoverImage.maximumRadius, style: .continuous)
                                .fill(Color.placeholderFill)
                                .aspectRatio(1, contentMode: .fit)
                            LibraryTileText(title: "Album Title", subtitle: "Artist · 2024")
                                .redacted(reason: .placeholder)
                        }
                    }
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
    }

    private static let names = ["Artist Name", "Someone", "A Longer Name", "Band", "The Artist", "Name Here"]
}
#endif

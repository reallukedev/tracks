import SwiftUI
import TracksCore

/// Every playlist you've made in Tracks, most recently changed first, with new ones a tap away:
/// a list of mosaics on iPhone, a grid of covers on the Mac.
struct PlaylistsPage: View {
    @Environment(YourMusic.self) private var music
    @Environment(AppModel.self) private var model
    @Environment(\.openPlayRoute) private var openPlayRoute
    @State private var makesPlaylist = false
    @State private var makesSmartPlaylist = false
    @State private var deleting: TracksPlaylist?
    @State private var renaming: TracksPlaylist?
    @State private var name = ""
    @State private var query = ""
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @ScaledMetric(relativeTo: .body) private var newRowScaled: CGFloat = 56

    var body: some View {
        content
            .navigationTitle("Playlists")
            .sheet(isPresented: $makesPlaylist) {
                NewPlaylistSheet { openPlayRoute(.tracksPlaylist($0.id)) }
            }
            .sheet(isPresented: $makesSmartPlaylist) {
                SmartPlaylistEditor(playlistID: nil) { openPlayRoute(.tracksPlaylist($0)) }
            }
            .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                    .titleEntry()
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let renaming { music.playlists.rename(renaming.id, to: name) }
                }
            }
            .confirmationDialog(
                "Delete \u{201C}\(deleting?.name ?? "")\u{201D}?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Playlist", role: .destructive) {
                    if let deleting { music.playlists.delete(deleting.id) }
                }
            } message: {
                Text("Its songs stay in your music.")
            }
            #if DEBUG
            .task(id: music.index.tracks.isEmpty) {
                CollectionDemo.seedPlaylists(music: music, isDemo: model.isDemoLaunch, open: openPlayRoute)
                if CollectionDemo.sheet == "new" { makesPlaylist = true }
            }
            #endif
    }

    private func menu(_ playlist: TracksPlaylist) -> some View {
        PlaylistMenu(playlist: playlist) {
            name = playlist.name
            renaming = playlist
        } delete: {
            deleting = playlist
        }
    }

    #if os(iOS)
    private var content: some View {
        let playlists = LibrarySort.filtered(music.playlists.recent, matching: query) { LibrarySortKeys(title: $0.name) }
        return List {
            if query.isEmpty {
                Section {
                    Button {
                        makesPlaylist = true
                    } label: {
                        newRow("New Playlist", systemImage: "plus")
                    }
                    .libraryRowInsets()
                    Button {
                        makesSmartPlaylist = true
                    } label: {
                        newRow("New Smart Playlist", systemImage: "gearshape")
                    }
                    .libraryRowInsets()
                } footer: {
                    if music.playlists.all.isEmpty {
                        Text("A smart playlist fills itself with the songs that fit its rules, and keeps up as your music changes.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
                .listSectionSeparator(.hidden, edges: .bottom)
            }
            if !playlists.isEmpty {
                Section {
                    ForEach(playlists) { playlist in
                        NavigationLink(value: PlayRoute.tracksPlaylist(playlist.id)) {
                            PlaylistRow(playlist: playlist)
                        }
                        .navigationLinkIndicatorVisibility(.hidden)
                        .libraryRowInsets()
                        .contextMenu { menu(playlist) }
                        .swipeActions(edge: .leading) {
                            Button("Play", systemImage: "play.fill") { play(playlist) }
                                .tint(.accentColor)
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = playlist }
                        }
                    }
                }
            } else if !query.isEmpty {
                LibraryNoMatches(query: query)
                    .libraryStateRow()
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .pageSearch(alwaysShown: false), prompt: "Filter Playlists")
    }

    private func play(_ playlist: TracksPlaylist) {
        let playable = music.songs(in: playlist, facts: feed.facts, factsRevision: feed.builtRevision).filter(music.isPlayable)
        guard !playable.isEmpty else { return }
        player.play(.local(playable), from: PlayContext(kind: .playlist, title: playlist.name))
    }

    private func newRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: newRowSide, height: newRowSide)
                .background(Color.cardFill, in: .rect(cornerRadius: CoverImage.radius(for: newRowSide), style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.tint)
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
    }

    /// The same side as a playlist's cover beside it.
    private var newRowSide: CGFloat { min(newRowScaled, 80) }
    #else
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LibraryPageHeader(
                    title: String(localized: "Playlists"),
                    subtitle: music.playlists.all.isEmpty ? nil : String(AttributedString(localized: "^[\(music.playlists.all.count) playlist](inflect: true)").characters)
                )
                if music.playlists.all.isEmpty {
                    CollectionMessage(
                        text: String(localized: "Make a playlist and add songs to it, or make a smart playlist that fills itself with the songs that fit."),
                        systemImage: "music.note.list"
                    ) {
                        HStack(spacing: 10) {
                            Button("New Playlist") { makesPlaylist = true }
                                .buttonStyle(.borderedProminent)
                            Button("New Smart Playlist") { makesSmartPlaylist = true }
                        }
                    }
                    .padding(.top, 60)
                } else {
                    LibraryGrid {
                        ForEach(music.playlists.recent) { playlist in
                            PlaylistTile(playlist: playlist) { menu(playlist) }
                        }
                    }
                }
            }
            .padding(.bottom, PlayMetrics.sectionSpacing)
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Playlist", systemImage: "music.note.list") { makesPlaylist = true }
                    Button("New Smart Playlist", systemImage: "gearshape") { makesSmartPlaylist = true }
                } label: {
                    Label("New Playlist", systemImage: "plus")
                } primaryAction: {
                    makesPlaylist = true
                }
                .help("New Playlist")
            }
        }
    }
    #endif

}

/// What can be done with one of your playlists from its row or tile.
private struct PlaylistMenu: View {
    let playlist: TracksPlaylist
    let rename: () -> Void
    let delete: () -> Void
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let playable = music.songs(in: playlist, facts: feed.facts, factsRevision: feed.builtRevision).filter(music.isPlayable)
        let context = PlayContext(kind: .playlist, title: playlist.name)
        Button("Play", systemImage: "play") { player.play(.local(playable), from: context) }
            .disabled(playable.isEmpty)
        Button("Shuffle", systemImage: "shuffle") { player.play(.local(playable), from: context, shuffled: true) }
            .disabled(playable.isEmpty)
        Divider()
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.enqueue(.local(playable), next: true, title: playlist.name) }
            .disabled(playable.isEmpty)
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { player.enqueue(.local(playable), next: false, title: playlist.name) }
            .disabled(playable.isEmpty)
        Divider()
        Button("Rename…", systemImage: "pencil", action: rename)
        Divider()
        Button("Delete Playlist…", systemImage: "trash", role: .destructive, action: delete)
    }
}

#if os(macOS)
/// A playlist in the Mac's grid, as the library's covers are: Play and More under the pointer,
/// its name and how many songs.
private struct PlaylistTile<Menu: View>: View {
    let playlist: TracksPlaylist
    @ViewBuilder var menu: Menu
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player

    var body: some View {
        let songs = music.songs(in: playlist, facts: feed.facts, factsRevision: feed.builtRevision)
        let playable = songs.filter(music.isPlayable)
        LibraryCoverTile(
            title: playlist.name,
            subtitle: PlaylistRow.summary(playlist, count: songs.count),
            route: .tracksPlaylist(playlist.id),
            play: playable.isEmpty ? nil : { player.play(.local(playable), from: PlayContext(kind: .playlist, title: playlist.name)) }
        ) { side in
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        PlaylistCover(songs: songs, isSmart: playlist.isSmart, seed: playlist.name, size: side ?? proxy.size.width)
                    }
                }
        } menu: {
            menu
        }
    }
}
#endif

/// A playlist in a list, as Music lists them: its cover, its name, and how many songs.
struct PlaylistRow: View {
    let playlist: TracksPlaylist
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 56

    var body: some View {
        let songs = music.songs(in: playlist, facts: feed.facts, factsRevision: feed.builtRevision)
        HStack(spacing: 12) {
            PlaylistCover(songs: songs, isSmart: playlist.isSmart, seed: playlist.name, size: min(side, 80))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .lineLimit(2)
                Text(Self.summary(playlist, count: songs.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .accessibilityElement(children: .combine)
    }

    /// "12 songs", or "Smart Playlist · 12 songs".
    static func summary(_ playlist: TracksPlaylist, count: Int) -> String {
        let songs = String(AttributedString(localized: "^[\(count) song](inflect: true)").characters)
        return playlist.isSmart ? String(localized: "Smart Playlist · \(songs)") : songs
    }
}

/// A playlist's cover: four of its albums' covers, or one where it has fewer, or a symbol
/// while it's empty.
struct PlaylistCover: View {
    let songs: [LocalTrack]
    var isSmart = false
    /// The playlist's name, for a stand-in cover while it's empty. A symbol on a plain tile
    /// without one.
    var seed: String?
    let size: CGFloat
    @Environment(YourMusic.self) private var music

    var body: some View {
        let covers = PlaylistCover.distinctCovers(of: songs)
        Group {
            if covers.count >= 4 {
                let half = size / 2
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        tile(covers[0], side: half)
                        tile(covers[1], side: half)
                    }
                    GridRow {
                        tile(covers[2], side: half)
                        tile(covers[3], side: half)
                    }
                }
            } else if let first = covers.first {
                tile(first, side: size)
            } else if let seed {
                // A playlist's own stand-in, the colour its page's field takes too.
                ArtworkView(url: nil, seed: seed, size: size, maximumCornerRadius: 0)
                    .overlay {
                        Image(systemName: isSmart ? "gearshape.fill" : "music.note.list")
                            .font(.system(size: size * 0.3, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    }
            } else {
                Image(systemName: isSmart ? "gearshape" : "music.note.list")
                    .font(.system(size: size * 0.32))
                    .foregroundStyle(.tint)
                    .frame(width: size, height: size)
                    .background(Color.cardFill)
            }
        }
        .clipShape(.rect(cornerRadius: CoverImage.radius(for: size), style: .continuous))
        .accessibilityHidden(true)
    }

    private func tile(_ song: LocalTrack, side: CGFloat) -> some View {
        ArtworkView(
            url: music.artworkURL(song.artwork)?.absoluteString,
            seed: song.album ?? song.title,
            size: side,
            maximumCornerRadius: 0
        )
    }

    /// The first songs from different albums, so the four covers differ.
    static func distinctCovers(of songs: [LocalTrack]) -> [LocalTrack] {
        var seen = Set<String>()
        var covers: [LocalTrack] = []
        for song in songs where covers.count < 4 && seen.insert(song.albumKey).inserted {
            covers.append(song)
        }
        return covers
    }
}

/// A playlist you made: play it, shuffle it, and change it. One you fill yourself can be
/// reordered and have songs taken out; a smart one changes as its rules find other songs.
struct TracksPlaylistPage: View {
    let playlistID: UUID
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var addsSongs = false
    @State private var editsRules = false
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmsDelete = false

    var body: some View {
        if let playlist = music.playlists.playlist(id: playlistID) {
            content(playlist)
        } else {
            ContentUnavailableView {
                Label("Playlist Not Found", systemImage: "music.note.list")
            } description: {
                Text("It may have been deleted on another device.")
            } actions: {
                Button("Go Back") { dismiss() }
            }
        }
    }

    private func content(_ playlist: TracksPlaylist) -> some View {
        let songs = music.songs(in: playlist, facts: feed.facts, factsRevision: feed.builtRevision)
        let playable = songs.filter(music.isPlayable)
        let context = PlayContext(kind: .playlist, title: playlist.name)
        return page(playlist, songs: songs, playable: playable, context: context)
            .toolbar {
                let downloadable = songs.filter { $0.isFromServer && music.isInYourMusic($0) }
                if !downloadable.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        AlbumDownloadButton(tracks: downloadable)
                            .help("Download Playlist")
                    }
                }
                #if os(iOS)
                // The Mac reorders and deletes rows without an editing mode.
                if !playlist.isSmart, !playlist.entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") { moreItems(playlist) }
                }
                #endif
            }
            #if DEBUG
            .task {
                switch CollectionDemo.sheet {
                case "add": addsSongs = true
                case "pick": music.playlists.picking = PlaylistPick(tracks: Array(songs.prefix(3)))
                default: break
                }
            }
            #endif
            .sheet(isPresented: $addsSongs) { AddSongsSheet(playlistID: playlist.id) }
            .sheet(isPresented: $editsRules) { SmartPlaylistEditor(playlistID: playlist.id) }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                    .titleEntry()
                Button("Cancel", role: .cancel) {}
                Button("Rename") { music.playlists.rename(playlist.id, to: name) }
            }
            .confirmationDialog("Delete \u{201C}\(playlist.name)\u{201D}?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Playlist", role: .destructive) {
                    dismiss()
                    music.playlists.delete(playlist.id)
                }
            } message: {
                Text("Its songs stay in your music.")
            }
    }

    #if os(iOS)
    private func page(_ playlist: TracksPlaylist, songs: [LocalTrack], playable: [LocalTrack], context: PlayContext) -> some View {
        List {
            Section {
                header(playlist, songs: songs, playable: playable, context: context)
            }

            if songs.isEmpty {
                emptyNote(playlist)
            } else if playlist.isSmart {
                Section {
                    ForEach(songs) { track in
                        row(track, playable: playable, context: context)
                    }
                } footer: {
                    footer(songs)
                }
            } else {
                Section {
                    ForEach(Array(zip(playlist.entries, songs)), id: \.0.id) { _, track in
                        row(track, playable: playable, context: context)
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { playlist.entries[$0].id })
                        music.playlists.update(playlist.id) { $0.remove(ids) }
                    }
                    .onMove { source, destination in
                        music.playlists.update(playlist.id) { $0.move(fromOffsets: source, toOffset: destination) }
                    }
                } footer: {
                    footer(songs)
                }
            }
        }
        .collectionPage(title: playlist.name)
        .animation(PlayMotion.row, value: songs.map(\.id))
    }

    private func row(_ track: LocalTrack, playable: [LocalTrack], context: PlayContext) -> some View {
        Button {
            play(track, in: playable, context: context)
        } label: {
            TrackRow(
                title: track.title,
                subtitle: track.artist,
                cover: cover(of: track),
                plays: feed.facts[track.identity]?.plays,
                isCurrent: player.current?.local?.id == track.id,
                localTrack: track,
                isPlayable: music.isPlayable(track)
            )
        }
        .buttonStyle(.plain)
        .disabled(!music.isPlayable(track))
        .trackMenu { LocalTrackMenu(track: track, showsStats: true) }
        .listRowInsets(EdgeInsets(top: 0, leading: PlayMetrics.margin, bottom: 0, trailing: 6))
    }

    private func footer(_ songs: [LocalTrack]) -> some View {
        CollectionFooter(lines: [TrackListFooter.summary(count: songs.count, seconds: songs.compactMap(\.duration).reduce(0, +))])
    }
    #else
    private func page(_ playlist: TracksPlaylist, songs: [LocalTrack], playable: [LocalTrack], context: PlayContext) -> some View {
        CollectionMacLayout {
            header(playlist, songs: songs, playable: playable, context: context)
        } content: {
            if songs.isEmpty {
                emptyNote(playlist)
            } else {
                macTable(playlist, songs: songs, playable: playable, context: context)
            }
        }
        .navigationTitle(playlist.name)
    }

    private func macTable(_ playlist: TracksPlaylist, songs: [LocalTrack], playable: [LocalTrack], context: PlayContext) -> some View {
        // A playlist you fill yourself has an entry per song, so the same song can be in it
        // twice and each be moved or taken out on its own; a smart one's songs are unique.
        let ids = playlist.isSmart ? songs.map(\.id) : playlist.entries.map(\.id.uuidString)
        let rows = zip(ids, songs).enumerated().map { position, pair in
            CollectionTrack(
                id: pair.0,
                position: position + 1,
                number: position + 1,
                title: pair.1.title,
                artist: pair.1.artist,
                album: pair.1.album ?? "",
                plays: feed.facts[pair.1.identity]?.plays ?? 0,
                duration: pair.1.duration ?? 0,
                isCurrent: player.current?.local?.id == pair.1.id,
                isPlayable: music.isPlayable(pair.1),
                // Each song's own cover, as Apple Music's playlists show them.
                artwork: .url(music.artworkURL(pair.1.artwork)?.absoluteString, seed: pair.1.album ?? pair.1.title),
                drag: SongDrag([pair.1]).songs.first
            )
        }
        let track = { (id: String) in zip(ids, songs).first { $0.0 == id }?.1 }
        return CollectionTable(
            tracks: rows,
            play: { id in
                if let found = track(id) { play(found, in: playable, context: context) }
            },
            enqueue: { chosen, next in
                let tracks = chosen.compactMap(track).filter(music.isPlayable)
                guard !tracks.isEmpty else { return }
                player.enqueue(.local(tracks), next: next, title: playlist.name)
            },
            removal: playlist.isSmart ? nil : .init(collection: playlist.name) { removed in
                music.playlists.update(playlist.id) { $0.remove(Set(removed.compactMap(UUID.init))) }
            },
            move: playlist.isSmart ? nil : { moved, destination in
                let offsets = IndexSet(moved.compactMap { id in playlist.entries.firstIndex { $0.id.uuidString == id } })
                guard !offsets.isEmpty else { return }
                music.playlists.update(playlist.id) { $0.move(fromOffsets: offsets, toOffset: destination) }
            }
        ) { row in
            if let found = track(row.id) {
                LocalTrackMenu(track: found, showsStats: true)
            }
        }
    }
    #endif

    private func header(_ playlist: TracksPlaylist, songs: [LocalTrack], playable: [LocalTrack], context: PlayContext) -> some View {
        let first = PlaylistCover.distinctCovers(of: songs).first
        let length = CollectionFacts.length(count: songs.count, seconds: songs.compactMap(\.duration).reduce(0, +))
        let facts: Text? = if let rules = playlist.rules {
            SmartRulesSummary.text(rules, length: length)
        } else {
            CollectionFacts.line([playlist.appleMusic.map { _ in String(localized: "Merged with Apple Music") }, length])
        }
        return CollectionHeader(
            kind: playlist.isSmart ? .smartPlaylist : .playlist,
            title: playlist.name,
            facts: facts,
            tintCover: .url(music.artworkURL(first?.artwork)?.absoluteString, seed: first?.album ?? playlist.name),
            canPlay: !playable.isEmpty,
            play: { player.play(.local(playable), from: context) },
            shuffle: { player.play(.local(playable), from: context, shuffled: true) }
        ) {
            moreItems(playlist)
        } cover: { side in
            PlaylistCover(songs: songs, isSmart: playlist.isSmart, seed: playlist.name, size: side)
        }
    }

    private func cover(of track: LocalTrack) -> CoverArt {
        .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title)
    }

    private func play(_ track: LocalTrack, in playable: [LocalTrack], context: PlayContext) {
        guard let start = playable.firstIndex(of: track) else { return }
        player.play(.local(playable, startingAt: start), from: context)
    }

    @ViewBuilder
    private func moreItems(_ playlist: TracksPlaylist) -> some View {
        if playlist.isSmart {
            Button("Edit Rules…", systemImage: "slider.horizontal.3") { editsRules = true }
        } else {
            Button("Add Songs…", systemImage: "plus") { addsSongs = true }
        }
        Button("Rename…", systemImage: "pencil") {
            name = playlist.name
            renaming = true
        }
        if playlist.appleMusic != nil {
            Button("Stop Merging with Apple Music", systemImage: "arrow.triangle.branch") {
                music.playlists.stopMerging(playlist.id)
            }
        }
        Divider()
        Button("Delete Playlist…", systemImage: "trash", role: .destructive) { confirmsDelete = true }
    }

    /// In the list's own place: what an empty playlist needs next.
    @ViewBuilder
    private func emptyNote(_ playlist: TracksPlaylist) -> some View {
        if playlist.isSmart {
            CollectionMessage(
                text: String(localized: "No songs match its rules yet. It fills itself as songs that fit come into your music."),
                systemImage: "gearshape"
            ) {
                Button("Edit Rules") { editsRules = true }
                    .buttonStyle(.bordered)
            }
        } else {
            CollectionMessage(
                text: String(localized: "Add songs from your music here, or from any song's menu."),
                systemImage: "music.note.list"
            ) {
                Button("Add Songs", systemImage: "plus") { addsSongs = true }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
    }
}

/// A smart playlist's rules in a line, for its header: "Artist contains “Nova” · Most Played".
enum SmartRulesSummary {
    static func text(_ rules: SmartRules, length: String?) -> Text {
        let complete = rules.conditions.filter(\.isComplete)
        let what: Text = switch complete.count {
        case 0:
            Text("Every song in your music")
        case 1:
            condition(complete[0])
        default:
            rules.match == .all
                ? Text("Matches all of ^[\(complete.count) rule](inflect: true)")
                : Text("Matches any of ^[\(complete.count) rule](inflect: true)")
        }
        var parts = [what]
        if rules.order != .random { parts.append(Text(rules.order.title)) }
        if let length { parts.append(Text(length)) }
        return parts.dropFirst().reduce(parts[0]) { line, part in Text("\(line) · \(part)") }
    }

    private static func condition(_ condition: SmartRules.Condition) -> Text {
        let field = Text(condition.field.title)
        let comparison = Text(condition.comparison.title)
        switch condition.field.kind {
        case .text:
            return Text("\(field) \(comparison) \u{201C}\(condition.text)\u{201D}")
        case .number:
            return Text("\(field) \(comparison) \(String(condition.number))")
        case .days:
            return Text("\(field) \(comparison) ^[\(condition.number) day](inflect: true)")
        case .quality:
            return Text("\(field) \(comparison)")
        }
    }
}

/// Names a new playlist, with songs already chosen for it or none.
struct NewPlaylistSheet: View {
    var tracks: [LocalTrack] = []
    var onCreate: (TracksPlaylist) -> Void = { _ in }
    @Environment(YourMusic.self) private var music
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var isNaming: Bool

    var body: some View {
        #if os(iOS)
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        PlaylistCover(songs: tracks, size: 120)
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                        TextField("Playlist Name", text: $name)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .titleEntry()
                            .focused($isNaming)
                            .submitLabel(.done)
                            .onSubmit(create)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                if !tracks.isEmpty {
                    Section {
                        ForEach(tracks.prefix(5)) { track in
                            TrackRow(title: track.title, subtitle: track.artist, cover: .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title))
                        }
                    } footer: {
                        if tracks.count > 5 {
                            Text("And \(tracks.count - 5) more")
                        }
                    }
                }
            }
            .navigationTitle("New Playlist")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", role: .confirm, action: create)
                }
            }
            .onAppear { isNaming = true }
        }
        .presentationDetents(tracks.isEmpty ? [.medium] : [.medium, .large])
        #else
        CollectionSheetLayout(title: String(localized: "New Playlist"), subtitle: subtitle) {
            HStack(alignment: .center, spacing: 14) {
                PlaylistCover(songs: tracks, size: 64)
                TextField("Playlist Name", text: $name, prompt: Text("New Playlist"))
                    .textFieldStyle(.roundedBorder)
                    .focused($isNaming)
                    .onSubmit(create)
            }
            .padding(.horizontal, 20)
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create", action: create)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 420)
        .defaultFocus($isNaming, true)
        #endif
    }

    #if os(macOS)
    /// What it'll hold: "With 12 songs", or where songs come from later.
    private var subtitle: String {
        tracks.isEmpty
            ? String(localized: "Add songs to it from your music, or from any song's menu.")
            : String(AttributedString(localized: "With ^[\(tracks.count) song](inflect: true)").characters)
    }
    #endif

    private func create() {
        let playlist = music.playlists.create(name: name, tracks: tracks)
        dismiss()
        onCreate(playlist)
    }
}

/// Chooses a playlist for songs picked from a menu, or makes a new one for them.
struct PlaylistPickerSheet: View {
    let pick: PlaylistPick
    @Environment(YourMusic.self) private var music
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var makesPlaylist: Bool

    /// Picks that came from New Playlist… in a menu, which skip straight to naming it.
    static var startsNew: Set<PlaylistPick.ID> = []

    init(pick: PlaylistPick) {
        self.pick = pick
        _makesPlaylist = State(initialValue: Self.startsNew.contains(pick.id))
    }

    var body: some View {
        content
            .onDisappear { Self.startsNew.remove(pick.id) }
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        NavigationStack {
            List {
                Button {
                    makesPlaylist = true
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
                ForEach(music.playlists.fillable) { playlist in
                    Button {
                        add(to: playlist)
                    } label: {
                        PlaylistRow(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Add to Playlist")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
            .sheet(isPresented: $makesPlaylist) {
                NewPlaylistSheet(tracks: pick.tracks) { playlist in
                    player.confirm(String(localized: "Added to \u{201C}\(playlist.name)\u{201D}"))
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
        #else
        if makesPlaylist {
            // Naming the new one takes this sheet's place rather than stacking a second.
            NewPlaylistSheet(tracks: pick.tracks) { playlist in
                player.confirm(String(localized: "Added to \u{201C}\(playlist.name)\u{201D}"))
            }
        } else {
            CollectionSheetLayout(title: String(localized: "Add to Playlist"), subtitle: songsLine) {
                if music.playlists.fillable.isEmpty {
                    Text("You haven't made a playlist yet.")
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                } else {
                    List(music.playlists.fillable) { playlist in
                        Button {
                            add(to: playlist)
                        } label: {
                            PlaylistRow(playlist: playlist)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(height: min(CGFloat(music.playlists.fillable.count) * 68 + 12, 340))
                }
            } actions: {
                Button("New Playlist…") { makesPlaylist = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .frame(width: 420)
        }
        #endif
    }

    #if os(macOS)
    private var songsLine: String {
        if pick.tracks.count == 1, let track = pick.tracks.first {
            return String(localized: "\u{201C}\(track.title)\u{201D} by \(track.artist)")
        }
        return String(AttributedString(localized: "^[\(pick.tracks.count) song](inflect: true)").characters)
    }
    #endif

    private func add(to playlist: TracksPlaylist) {
        music.playlists.add(pick.tracks, to: playlist.id)
        player.confirm(String(localized: "Added to \u{201C}\(playlist.name)\u{201D}"))
        dismiss()
    }
}

/// Adds songs from your music to a playlist: your newest first, or what you search for.
struct AddSongsSheet: View {
    let playlistID: UUID
    @Environment(YourMusic.self) private var music
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Added while the sheet's been open, for their checkmarks.
    @State private var added: Set<String> = []
    @FocusState private var isSearching: Bool

    var body: some View {
        #if os(iOS)
        NavigationStack {
            List {
                if results.isEmpty {
                    emptyMessage
                }
                ForEach(results) { track in
                    HStack(spacing: 4) {
                        TrackRow(
                            title: track.title,
                            subtitle: track.artist,
                            cover: .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title)
                        )
                        addButton(track)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .pageSearch(), prompt: "Your Music")
            .navigationTitle("Add Songs")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
        }
        #else
        CollectionSheetLayout(title: String(localized: "Add Songs"), subtitle: subtitle) {
            VStack(spacing: 10) {
                CollectionSheetSearchField(prompt: "Search Your Music", text: $query)
                    .focused($isSearching)
                    .padding(.horizontal, 20)
                List {
                    if results.isEmpty {
                        emptyMessage
                    }
                    ForEach(results) { track in
                        HStack(spacing: 10) {
                            LocalCover(artwork: track.artwork, seed: track.album ?? track.title, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            addButton(track)
                        }
                        .frame(minHeight: 36)
                    }
                }
                .listStyle(.inset)
                .frame(height: 360)
            }
        } actions: {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 480)
        .defaultFocus($isSearching, true)
        #endif
    }

    #if os(macOS)
    private var subtitle: String? {
        music.playlists.playlist(id: playlistID).map { String(localized: "To \u{201C}\($0.name)\u{201D}") }
    }
    #endif

    private func addButton(_ track: LocalTrack) -> some View {
        let isAdded = added.contains(track.id)
        return Button {
            music.playlists.add([track], to: playlistID)
            withAnimation(PlayMotion.value) { _ = added.insert(track.id) }
        } label: {
            Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
                .font(.title3)
                .contentTransition(.symbolEffect(.replace))
                #if os(iOS)
                .frame(width: 44, height: 44)
                #else
                .frame(width: 28, height: 28)
                #endif
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(isAdded)
        .help(isAdded ? "Added" : "Add to Playlist")
        .accessibilityLabel(isAdded ? "Added" : "Add")
    }

    @ViewBuilder
    private var emptyMessage: some View {
        if query.isEmpty {
            CollectionMessage(text: String(localized: "Songs you import or sync from a server show here."), systemImage: "music.note")
        } else {
            CollectionMessage(text: String(localized: "No songs in your music match \u{201C}\(query)\u{201D}."), systemImage: "magnifyingglass")
        }
    }

    private var results: [LocalTrack] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return Array(music.index.tracks.sorted { $0.addedAt > $1.addedAt }.prefix(100))
        }
        return music.index.search(query, limit: 100).tracks
    }
}

import SwiftUI
import UniformTypeIdentifiers
import MusicKit
import TracksCore

/// Play, when your own music is the source: Tracks Radio from everything you own, what's new,
/// your mixes and moods from your files and servers, what each server has to discover, and
/// your whole library a tap away.
struct YourMusicScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @Environment(Lidarr.self) private var lidarr
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PlayPreferences.tracksRadioKey) private var isRadioOn = true
    @AppStorage(SuggestionMode.storageKey) private var suggestionMode = SuggestionMode.everything
    @AppStorage(PlayPreferences.layoutKey) private var storedLayout = ""
    @AppStorage(NearbyDevices.storageKey) private var showsDevices = true
    @State private var showsSettings = LaunchScene.opensPlaySettings
    @State private var importMode: ImportMode?
    @State private var addsServer = false
    /// A server whose password needs typing again.
    @State private var signingIn: SubsonicServer?
    @State private var shelves = Shelves()

    enum ImportMode { case files, folder }

    var body: some View {
        ScrollView {
            // Lazy, so shelves below the fold are made, and ask their servers, as they come.
            LazyVStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                if !music.index.isEmpty {
                    content
                } else if !music.servers.syncing.isEmpty || (!music.hasScanned && music.servers.servers.isEmpty) {
                    // Reading the files, or a server's first sync.
                    VStack(alignment: .leading, spacing: 8) {
                        if !music.servers.syncing.isEmpty {
                            Label("Getting your server's songs…", systemImage: "arrow.triangle.2.circlepath")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        LoadingRows(count: 6)
                    }
                    .padding(.horizontal, PlayMetrics.margin)
                } else if !music.servers.onlineServers.isEmpty {
                    // A server that answered with no songs, Octo's often: what it picks for you
                    // leads, to play and add.
                    content
                } else {
                    YourMusicWelcome(
                        hasServers: !music.servers.servers.isEmpty,
                        importFiles: { importMode = .files },
                        importFolder: { importMode = .folder },
                        addServer: { addsServer = true }
                    )
                    .padding(.horizontal, PlayMetrics.margin)
                }
            }
            #if os(macOS)
            .padding(.top, 20)
            #else
            .padding(.top, 4)
            #endif
            .padding(.bottom, 24)
        }
        .launchScroll()
        .overlay(alignment: .top) {
            if let result = music.lastImport {
                ImportBanner(result: result)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: music.lastImport?.added)
        #if os(iOS)
        .navigationTitle("Play")
        #else
        // No title over the page, and its glow meets the top edge until it scrolls under the bar.
        .headerUnderBar()
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(iOS)
                if showsDevices { DevicesButton() }
                #endif
                Menu("Add Music", systemImage: "plus") {
                    Button("Import Songs", systemImage: "music.note") { importMode = .files }
                    Button("Import a Folder", systemImage: "folder") { importMode = .folder }
                    #if os(macOS)
                    Button("Show Music Folder in Finder", systemImage: "folder.badge.gearshape") {
                        LibraryFolders.prepare()
                        NSWorkspace.shared.activateFileViewerSelecting([LibraryFolders.music])
                    }
                    #endif
                    Divider()
                    Button("Connect a Server", systemImage: "server.rack") { addsServer = true }
                }
                #if os(iOS)
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
                #endif
            }
        }
        .fileImporter(
            isPresented: Binding(get: { importMode != nil }, set: { if !$0 { importMode = nil } }),
            allowedContentTypes: importMode == .folder ? [.folder] : [.audio],
            allowsMultipleSelection: importMode != .folder
        ) { result in
            if case .success(let urls) = result {
                Task { await music.importItems(urls) }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
        #endif
        .sheet(isPresented: $addsServer) { ServerForm() }
        .sheet(item: $signingIn) { server in ServerForm(editing: server) }
        .refreshCommand()
        .refreshable {
            await music.scan()
            await music.servers.connectAll()
            music.forgetUnavailable()
        }
        // Sample data's suggestions stand in for a server's; nothing else here asks Apple Music.
        .task(id: player.isDemo) {
            guard player.isDemo, suggestionMode != .off else { return }
            await feed.loadFromYourArtists()
        }
        // The shelves made from your music, worked out when what they're made from changes
        // rather than on every redraw.
        .task(id: ShelvesKey(songs: music.index.tracks.count, history: feed.builtRevision, downloads: music.downloads.items.count, mixes: feed.mixes.mixes.count)) {
            shelves = makeShelves()
        }
    }

    /// The crate for your own music: Tracks Radio in the middle, starting in front, with this
    /// hour's mix and the rest of the day's either side, each only if enough of its songs are
    /// yours to play.
    private func crateCards(hasRadio: Bool) -> [ForYouCard] {
        var cards: [ForYouCard] = []
        if let lead = feed.mixes.rightNow, isPlayable(lead) { cards.append(.mix(lead)) }
        cards += feed.mixes.otherTimes.filter(isPlayable).map(ForYouCard.mix)
        if hasRadio { cards.insert(.station, at: cards.count / 2) }
        return cards
    }

    /// A mix with at least five of its songs in your music, as the shelf of mixes asks.
    private func isPlayable(_ mix: Mix) -> Bool {
        mix.songs.lazy.filter { music.track(for: HistorySong($0)) != nil }.prefix(5).count >= 5
    }

    /// The shelves made from your music, kept between redraws. See ``makeShelves()``.
    struct Shelves {
        var mixes: [Mix] = []
        var unplayed: [LocalTrack] = []
        var downloaded: [LocalTrack] = []
        /// Albums of yours, most lately heard first.
        var recentlyPlayed: [LocalAlbum] = []
        /// The artists you play most lately who are in your music.
        var artists: [(artist: LocalArtist, plays: Int)] = []
    }

    private struct ShelvesKey: Equatable {
        let songs: Int
        /// The history read again: new plays.
        let history: Int?
        let downloads: Int
        let mixes: Int
    }

    private func makeShelves() -> Shelves {
        let seed = FreshShuffle.dailySeed(for: .now, salt: "waiting")
        let blocked = player.signals.blocked
        let unplayed = music.index.tracks.filter { feed.facts[$0.identity] == nil && music.isPlayable($0) && !blocked.blocks(songBy: $0.artist) }
        let onPhone = music.index.tracks.filter { !$0.isFromServer || music.downloads.isDownloaded($0.id) }
        // Songs on this iPhone: ones you haven't played first, then the ones you've played
        // least lately, a fresh order each day.
        let downloaded = FreshShuffle.order(
            onPhone,
            artist: \.artistKey,
            recentlyHeard: { feed.facts[$0.identity] != nil },
            seed: FreshShuffle.dailySeed(for: .now, salt: "downloads")
        )
        // Each album by the last time you heard any song on it.
        let heard = music.index.albums.compactMap { album -> (album: LocalAlbum, at: Date)? in
            let last = album.tracks.compactMap { feed.facts[$0.identity]?.lastHeard }.max()
            return last.map { (album, $0) }
        }
        let artists = feed.favoriteArtists.compactMap { favorite in
            music.index.artist(id: favorite.id).map { (artist: $0, plays: favorite.plays) }
        }
        return Shelves(
            mixes: feed.mixes.mixes.filter { mix in
                mix.songs.lazy.filter { music.track(for: HistorySong($0)) != nil }.count >= 5
            },
            unplayed: Array(FreshShuffle.order(unplayed, artist: \.artistKey, seed: seed).prefix(15)),
            downloaded: Array(downloaded.prefix(15)),
            recentlyPlayed: Array(heard.sorted { $0.at > $1.at }.prefix(15).map(\.album)),
            artists: artists
        )
    }

    private var layout: PlayLayout { PlayLayout(stored: storedLayout) }

    /// Tracks Radio plays from your music, and from what your servers find for you.
    private var hasRadio: Bool {
        isRadioOn && (!music.index.isEmpty || !music.servers.onlineServers.isEmpty)
    }

    /// The crate leads, as on Apple Music's Play: Tracks Radio, this hour's mix, the rest of
    /// the day's, and songs past them either way.
    private var crate: [ForYouCard] { crateCards(hasRadio: hasRadio) }

    /// Whether the crate is on the page, with anything in it.
    private var hasCrate: Bool { layout.isVisible(.forYou) && !crate.isEmpty }

    /// Play's sections in the order chosen in Edit Play, the same layout as Apple Music's,
    /// with your own music where Apple's would be: what's waiting to be heard where Apple has
    /// new releases, your downloads where it has charts, your servers' picks where it has its
    /// own. A server that can't be reached says so first, since it's why its shelves are gone.
    @ViewBuilder
    private var content: some View {
        ForEach(music.servers.servers.filter { ServerProblem(music.servers.status[$0.id]) != nil }) { server in
            ServerProblemCard(server: server, signIn: { signingIn = server })
                .padding(.horizontal, PlayMetrics.margin)
        }
        ForEach(layout.visible.filter { $0.isOffered(for: .yourMusic) }) { section in
            self.section(section)
                .id(section.rawValue)
        }
        // One endless list at the bottom: what you have and haven't played, and more your
        // servers find for you, as Apple Music's Play ends with Keep Exploring.
        if player.isDemo, suggestionMode != .off {
            KeepExploringSection(followsShelf: layout.isVisible(.suggestedSongs))
        } else if !music.servers.onlineServers.isEmpty {
            ServerExploring()
        }
    }

    @ViewBuilder
    private func section(_ section: PlaySection) -> some View {
        let servers = music.servers.onlineServers
        let suggests = suggestionMode != .off
        switch section {
        case .forYou:
            if hasCrate {
                ForYouCrate(cards: crate, leadID: crate.contains { $0.id == "station" } ? "station" : crate.first { if case .mix = $0 { true } else { false } }?.id)
            }
        case .suggestedSongs:
            // Tracks Radio leads the crate; with the crate hidden or empty, it leads these.
            let radioHere = hasRadio && !hasCrate
            if player.isDemo, suggests {
                // Sample data has no server: its suggestions stand in, from the sample catalog.
                SuggestedSongsSection(includesRadio: radioHere)
            } else if suggests, !servers.isEmpty {
                // Songs by artists new to you your server found.
                ForEach(servers) { server in
                    ServerForYouSection(server: server, shelf: .suggested, includesRadio: radioHere)
                }
            } else if radioHere {
                TracksRadioRow()
                    .padding(.horizontal, PlayMetrics.margin)
            }
        case .recentlyPlayed:
            if !shelves.recentlyPlayed.isEmpty {
                Shelf(title: String(localized: "Recently Played"), items: shelves.recentlyPlayed) { album in
                    LocalAlbumTile(album: album)
                }
            }
        case .yourArtists:
            if !shelves.artists.isEmpty {
                Shelf(title: String(localized: "Your Artists"), items: shelves.artists.map(YourArtist.init)) { item in
                    YourArtistTile(artist: item.artist, plays: item.plays)
                }
            }
        case .mixes:
            // The mixes the crate doesn't already hold.
            let shelfMixes = shelves.mixes.filter { mix in !(hasCrate && crate.contains { $0.id == mix.id }) }
            if !shelfMixes.isEmpty {
                Shelf(title: String(localized: "Made from Your Listening"), items: shelfMixes) { mix in
                    MixTile(mix: mix)
                }
            }
        case .moods:
            MoodShelf()
        case .genres:
            GenreShelf()
        case .newReleases:
            if !shelves.unplayed.isEmpty {
                Shelf(title: String(localized: "Waiting to Be Heard"), items: shelves.unplayed) { track in
                    LocalTrackTile(track: track, queue: shelves.unplayed, context: .songs(String(localized: "Waiting to Be Heard")))
                }
            }
        case .charts:
            if !shelves.downloaded.isEmpty {
                Shelf(title: String(localized: "From Your Downloads"), items: shelves.downloaded) {
                    HStack(spacing: 16) {
                        ShuffleDownloadsButton()
                            .labelStyle(.iconOnly)
                        NavigationLink(String(localized: "Manage"), value: PlayRoute.yourMusic(.downloads))
                    }
                } tile: { track in
                    LocalTrackTile(track: track, queue: shelves.downloaded, context: .songs(String(localized: "From Your Downloads")))
                }
            }
        case .library:
            #if os(iOS)
            // The Mac's library is in its sidebar.
            LibraryList()
                .padding(.horizontal, PlayMetrics.margin)
            #endif
        case .appleMusic:
            // What your servers pick for you, and their own shelves, where Apple Music's picks
            // would be.
            if suggests {
                ForEach(servers) { server in
                    ServerForYouSection(server: server, shelf: .picks)
                }
            }
            ForEach(servers) { server in
                ServerShelves(server: server)
            }
        case .suggestedArtists, .radio:
            // Apple Music's own: your music has neither.
            EmptyView()
        }
    }
}

/// What's wrong with a server, for the card that says so. Nil while it's fine or connecting.
private enum ServerProblem {
    case offline, wrongPassword, failed(String)

    init?(_ status: MusicServers.Status?) {
        switch status {
        case .offline: self = .offline
        case .wrongPassword: self = .wrongPassword
        case .failed(let reason): self = .failed(reason)
        case .online, .connecting, nil: return nil
        }
    }
}

/// A server that can't be reached, in place at the top of Play: what's wrong, what still
/// plays, and the one thing to do about it.
private struct ServerProblemCard: View {
    let server: SubsonicServer
    let signIn: () -> Void
    @Environment(YourMusic.self) private var music
    @State private var isRetrying = false

    var body: some View {
        let problem = ServerProblem(music.servers.status[server.id])
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol(problem))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(problem))
                    .font(.subheadline.weight(.semibold))
                Text(message(problem))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if case .wrongPassword = problem {
                Button("Sign In", action: signIn)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            } else if isRetrying {
                ProgressView()
                    .frame(minWidth: 44)
            } else {
                Button("Try Again") {
                    isRetrying = true
                    Task {
                        await music.servers.connect(server.id)
                        isRetrying = false
                    }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(16)
        .background(Color.cardFill, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func symbol(_ problem: ServerProblem?) -> String {
        if case .wrongPassword = problem { return "key" }
        return "wifi.exclamationmark"
    }

    private func title(_ problem: ServerProblem?) -> String {
        switch problem {
        case .wrongPassword: String(localized: "\(server.name) Needs Signing In Again")
        default: String(localized: "Can't Reach \(server.name)")
        }
    }

    private func message(_ problem: ServerProblem?) -> String {
        switch problem {
        case .wrongPassword: String(localized: "Its password has changed. Songs you've downloaded still play.")
        case .failed(let reason): String(localized: "\(reason) Songs you've downloaded still play.")
        default: String(localized: "Songs you've downloaded still play.")
        }
    }
}

/// An artist on Your Artists, identified for the shelf.
private struct YourArtist: Identifiable {
    let artist: LocalArtist
    let plays: Int
    var id: String { artist.id }

    init(_ item: (artist: LocalArtist, plays: Int)) {
        artist = item.artist
        plays = item.plays
    }
}

/// One of the artists you play most, as Apple Music's Your Artists has them: their picture
/// and your plays, opening their page.
private struct YourArtistTile: View {
    let artist: LocalArtist
    let plays: Int
    @Environment(YourMusic.self) private var music

    var body: some View {
        NavigationLink(value: PlayRoute.localArtist(artist.id)) {
            ArtistCircleTile(name: artist.name, picture: music.artistPicture(for: artist), detail: PlayCountText.short(plays))
        }
        .buttonStyle(.pressable)
        .contextMenu { LocalArtistMenu(artist: artist) }
    }
}

/// A song of yours on a shelf: plays the shelf from it.
struct LocalTrackTile: View {
    let track: LocalTrack
    let queue: [LocalTrack]
    let context: PlayContext
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Button {
            player.play(.local(queue, startingAt: queue.firstIndex(of: track) ?? 0), from: context)
        } label: {
            TileLabel(title: track.title, subtitle: track.artist) { side in
                LocalCover(artwork: track.artwork, seed: track.album ?? track.title, size: side)
            }
        }
        .buttonStyle(.pressable)
        .contextMenu { LocalTrackMenu(track: track, showsStats: true) }
    }
}

#if os(iOS)
/// Your library on Play, as Apple Music's begins: its parts as rows in Music's order, then
/// what came into it lately as a grid. The Mac has these in its sidebar.
private struct LibraryList: View {
    @Environment(YourMusic.self) private var music
    @Environment(Lidarr.self) private var lidarr

    /// Three rows of two: enough to see what's new without taking over Play.
    private static let recentCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Library")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                rows
            }
            let recent = Array(music.index.recentlyAdded.prefix(Self.recentCount))
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Recently Added")
                            .font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if music.index.albums.count > recent.count {
                            NavigationLink("See All", value: PlayRoute.yourMusic(.recentlyAdded))
                                .font(.subheadline)
                        }
                    }
                    LibraryGrid(margin: 0) {
                        ForEach(recent) { album in
                            LocalAlbumGridTile(album: album)
                        }
                    }
                }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(lists) { list in
                row(list.title, symbol: list.symbol, route: .yourMusic(list), status: status(of: list))
                if list != lists.last || lidarr.isSetUp {
                    Divider().padding(.leading, 58)
                }
            }
            if lidarr.isSetUp {
                row(
                    "Lidarr",
                    symbol: "tray.and.arrow.down",
                    route: .lidarr,
                    status: lidarr.queue.isEmpty ? nil : String(localized: "\(lidarr.queue.count) downloading")
                )
            }
        }
        .background(Color.cardFill)
        .clipShape(.rect(cornerRadius: 16, style: .continuous))
    }

    /// Music's order, Playlists, Artists, Albums, Songs, then Downloads once there's a server
    /// to download from or anything downloaded.
    private var lists: [YourMusicList] {
        var lists: [YourMusicList] = [.playlists, .artists, .albums, .songs]
        if !music.servers.servers.isEmpty || !music.downloads.items.isEmpty { lists.append(.downloads) }
        return lists
    }

    /// Only what's under way: "3 downloading".
    private func status(of list: YourMusicList) -> String? {
        guard list == .downloads else { return nil }
        let active = music.downloads.downloading.count
        return active > 0 ? String(localized: "\(active) downloading") : nil
    }

    private func row(_ title: LocalizedStringKey, symbol: String, route: PlayRoute, status: String?) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if let status {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
    }
}
#endif

/// What to do with an empty library: bring songs in, or connect a server.
private struct YourMusicWelcome: View {
    /// A server's been added, but can't be reached.
    var hasServers = false
    let importFiles: () -> Void
    let importFolder: () -> Void
    let addServer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: -10) {
                ForEach(["waveform", "folder.fill", "server.rack"], id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor.gradient, in: .circle)
                        .overlay { Circle().stroke(Color.cardFill, lineWidth: 3) }
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 10) {
                Button(action: importFiles) {
                    Label("Import Songs", systemImage: "music.note").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: importFolder) {
                    Label("Import a Folder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button(action: addServer) {
                    Label("Connect a Server", systemImage: "server.rack").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            Text(folderNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private var title: LocalizedStringKey {
        hasServers ? "Nothing Here Yet" : "Your Music, Your Way"
    }

    private var folderNote: LocalizedStringKey {
        #if os(macOS)
        "You can also drop music into the Tracks Music folder, which Add Music shows in Finder. FLAC, ALAC, MP3, AAC, WAV and AIFF all play."
        #else
        "You can also drop music into On My iPhone › Tracks › Music in the Files app. FLAC, ALAC, MP3, AAC, WAV and AIFF all play."
        #endif
    }

    private var message: LocalizedStringKey {
        #if os(macOS)
        hasServers
            ? "Your server can't be reached right now. Try again from Settings, or import songs to this Mac."
            : "Play the FLAC and other files you own, and music from your own server. Every song you play is kept in your history, with Tracks Radio, mixes and moods made from all of it."
        #else
        hasServers
            ? "Your server can't be reached right now. Pull down to try again, or import songs to this iPhone."
            : "Play the FLAC and other files you own, and music from your own server. Every song you play is kept in your history, with Tracks Radio, mixes and moods made from all of it."
        #endif
    }
}

/// "Added 12 songs", for a moment after an import.
private struct ImportBanner: View {
    let result: FileScanner.ImportResult

    var body: some View {
        Label(message, systemImage: result.added > 0 ? "checkmark.circle.fill" : "info.circle.fill")
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
    }

    private var message: String {
        if result.added > 0 {
            return String(AttributedString(localized: "Added ^[\(result.added) song](inflect: true)").characters)
        }
        return result.skipped > 0 ? String(localized: "Already in your music") : String(localized: "No songs found to add")
    }
}

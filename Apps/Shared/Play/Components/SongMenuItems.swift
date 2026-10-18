import SwiftUI
import MusicKit
import TracksCore

/// What can be done with one song, whatever it is underneath: an Apple Music song, one from
/// the history, or one of your own. Each kind of song fills in what it can, and
/// ``SongMenuItems`` lays it out the same way everywhere.
struct SongActions {
    var play: (() -> Void)?
    var playNext: (() -> Void)?
    var playLast: (() -> Void)?
    var createStation: (() -> Void)?
    var addToLibrary: (() -> Void)?
    /// Your music's own ways of keeping a song, beside Add to Library: Download, Keep on This
    /// Mac, Ask Lidarr.
    var keep: [SongMenuButton] = []
    /// Songs of yours, for Add to Playlist. Empty leaves it out.
    var playlistTracks: [LocalTrack] = []
    /// An Apple Music song, for Favorite.
    var favorite: Song?
    var goToAlbum: (() -> Void)?
    var goToArtist: (() -> Void)?
    /// Each artist a collaboration credits, for a Go to Artist that asks which, as Music's
    /// does. Used over ``goToArtist`` when there are two or more.
    var artistLinks: [ArtistLink] = []
    var stats: (() -> Void)?
    /// Show in Finder or Show in Music, after Your Stats.
    var reveal: [SongMenuButton] = []
    var share: SongShare?
    /// The song's identity, for Suggest Less. Nil leaves it out.
    var suggestLess: String?
    /// Who the song is by, for Block. Nil leaves it out.
    var block: String?
    /// Steering a live mix, after Suggest Less: Play More Like This.
    var steer: [SongMenuButton] = []
    /// Last, after a divider: Remove from Playlist, Delete, Tune Tracks Radio.
    var trailing: [SongMenuButton] = []
}

/// One artist in a Go to Artist menu.
struct ArtistLink {
    let name: String
    let action: () -> Void
}

extension SongActions {
    /// Links to each artist the song credits, when it credits more than one.
    mutating func linkArtists(_ credits: [ArtistCredit], to go: @escaping (ArtistCredit) -> Void) {
        artistLinks = credits.count > 1 ? credits.map { credit in ArtistLink(name: credit.name) { go(credit) } } : []
    }
}

/// Go to Artist: one item for one artist, or a menu of each for a collaboration.
struct GoToArtistItem: View {
    let actions: SongActions

    var body: some View {
        if actions.artistLinks.count > 1 {
            Menu("Go to Artist", systemImage: "music.microphone") {
                ForEach(actions.artistLinks.indices, id: \.self) { index in
                    let link = actions.artistLinks[index]
                    Button(action: link.action) { Text(verbatim: link.name) }
                }
            }
        } else if let goToArtist = actions.goToArtist {
            Button("Go to Artist", systemImage: "music.microphone", action: goToArtist)
        }
    }
}

/// One item of a song's menu that only some songs have.
struct SongMenuButton {
    let title: LocalizedStringKey
    let systemImage: String
    var role: ButtonRole?
    var isDisabled = false
    let action: () -> Void
}

/// What Share… hands on: the song's link, or its name where it has none.
enum SongShare {
    case url(URL)
    case text(String)

    /// An Apple Music song by its catalog id, or its name when it has none.
    static func song(id: String, title: String, artist: String) -> SongShare {
        if !id.isEmpty, id.allSatisfy(\.isNumber), let url = URL(string: "https://music.apple.com/song/\(id)") {
            return .url(url)
        }
        return .text(String(localized: "\(title) by \(artist)"))
    }
}

/// Every song's menu, in one order, with one name for each action: Play, Play Next, Play Last ·
/// Create Station · Add to Library, Add to Playlist, Favorite · Go to Album, Go to Artist, Your
/// Stats · Share… · Suggest Less, Block · and Remove or Delete where they apply. A group with
/// nothing in it takes its divider with it.
struct SongMenuItems: View {
    let actions: SongActions

    init(_ actions: SongActions) {
        self.actions = actions
    }

    private var hasPlay: Bool { actions.play != nil || actions.playNext != nil || actions.playLast != nil }
    private var hasLibrary: Bool { actions.addToLibrary != nil || !actions.keep.isEmpty || !actions.playlistTracks.isEmpty || actions.favorite != nil }
    private var hasGo: Bool { actions.goToAlbum != nil || actions.goToArtist != nil || !actions.artistLinks.isEmpty || actions.stats != nil || !actions.reveal.isEmpty }

    var body: some View {
        let groups = [hasPlay, actions.createStation != nil, hasLibrary, hasGo, actions.share != nil]
        let hasFeedback = actions.suggestLess != nil || actions.block != nil || !actions.steer.isEmpty

        if let play = actions.play {
            Button("Play", systemImage: "play", action: play)
        }
        if let playNext = actions.playNext {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: playNext)
        }
        if let playLast = actions.playLast {
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward", action: playLast)
        }

        if let createStation = actions.createStation {
            if groups[..<1].contains(true) { Divider() }
            Button("Create Station", systemImage: "dot.radiowaves.left.and.right", action: createStation)
        }

        if hasLibrary {
            if groups[..<2].contains(true) { Divider() }
            if let addToLibrary = actions.addToLibrary {
                Button("Add to Library", systemImage: "plus", action: addToLibrary)
            }
            buttons(actions.keep)
            if !actions.playlistTracks.isEmpty {
                AddToPlaylistMenu(tracks: actions.playlistTracks)
            }
            if let song = actions.favorite {
                FavoriteMenuItem(song: song)
            }
        }

        if hasGo {
            if groups[..<3].contains(true) { Divider() }
            if let goToAlbum = actions.goToAlbum {
                Button("Go to Album", systemImage: "square.stack", action: goToAlbum)
            }
            GoToArtistItem(actions: actions)
            if let stats = actions.stats {
                Button("Your Stats", systemImage: "chart.bar.xaxis", action: stats)
            }
            buttons(actions.reveal)
        }

        if let share = actions.share {
            if groups[..<4].contains(true) { Divider() }
            switch share {
            case .url(let url):
                ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            case .text(let text):
                ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up") }
            }
        }

        if hasFeedback {
            if groups.contains(true) { Divider() }
            if let identity = actions.suggestLess {
                SuggestLessButton(songIdentity: identity)
            }
            buttons(actions.steer)
            if let credit = actions.block {
                BlockArtistButton(songBy: credit)
            }
        }

        if !actions.trailing.isEmpty {
            if groups.contains(true) || hasFeedback { Divider() }
            buttons(actions.trailing)
        }
    }

    private func buttons(_ items: [SongMenuButton]) -> some View {
        ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            Button(item.title, systemImage: item.systemImage, role: item.role, action: item.action)
                .disabled(item.isDisabled)
        }
    }
}

extension SongActions {
    /// An Apple Music song's actions.
    /// - Parameters:
    ///   - go: where Go to Album, Go to Artist and Your Stats lead.
    ///   - showsAlbum: off on the album's own page.
    ///   - showsArtist: off on the artist's own page.
    ///   - showsSuggestLess: off where the menu has its own way to say no, as suggestions do.
    static func catalog(
        _ song: Song,
        player: PlayerModel,
        play: (() -> Void)? = nil,
        go: ((PlayRoute) -> Void)?,
        showsAlbum: Bool = true,
        showsArtist: Bool = true,
        showsSuggestLess: Bool = true
    ) -> SongActions {
        let identity = HistoryImport.key(title: song.title, artistName: song.artistName)
        var actions = SongActions(
            play: play,
            playNext: { player.enqueue(.songs([song]), next: true, title: song.title) },
            playLast: { player.enqueue(.songs([song]), next: false, title: song.title) },
            createStation: { player.playStation(from: song) },
            addToLibrary: { player.addToLibrary(song) },
            favorite: song,
            share: song.url.map(SongShare.url)
        )
        if let go {
            actions.stats = { go(.stats(.song(identity))) }
            if showsAlbum {
                actions.goToAlbum = { Task { if let album = await SongLinks.album(of: song) { go(.album(album)) } } }
            }
            if showsArtist {
                actions.goToArtist = { Task { if let artist = await SongLinks.artist(of: song) { go(.artist(artist)) } } }
                actions.linkArtists(ArtistCredits.song(artist: song.artistName, title: song.title)) { credit in
                    go(.artistNamed(credit.name, identity: credit.identity))
                }
            }
        }
        if showsSuggestLess {
            actions.suggestLess = identity
            actions.block = song.artistName
        }
        return actions
    }

    /// A song known from the history by its catalog id and name. Its album is your history's
    /// page for it; its artist is found in Apple Music by name, as a favorite artist's is.
    static func history(
        _ song: MixSong,
        player: PlayerModel,
        play: (() -> Void)? = nil,
        go: ((PlayRoute) -> Void)?
    ) -> SongActions {
        let canPlay = player.canPlay(songID: song.songID)
        let credits = ArtistCredits.song(artist: song.artistName, title: song.title)
        let artistIdentity = credits.first?.identity ?? StatsCalculator.folded(song.artistName)
        let album = song.albumTitle.map(StatsCalculator.folded) ?? ""
        var actions = SongActions(
            play: canPlay ? play : nil,
            share: player.isDemo ? nil : .song(id: song.songID, title: song.title, artist: song.artistName),
            suggestLess: song.songIdentity,
            block: song.artistName
        )
        if let go {
            if !album.isEmpty {
                actions.goToAlbum = { go(.stats(.album("\(album)\u{1F}\(artistIdentity)"))) }
            }
            let lead = credits.first?.name ?? song.artistName
            actions.goToArtist = { go(.artistNamed(lead, identity: artistIdentity)) }
            actions.linkArtists(credits) { go(.artistNamed($0.name, identity: $0.identity)) }
            actions.stats = { go(.stats(.song(song.songIdentity))) }
        }
        if canPlay {
            actions.playNext = { player.enqueue(.history([HistorySong(song)]), next: true, title: song.title) }
            actions.playLast = { player.enqueue(.history([HistorySong(song)]), next: false, title: song.title) }
        }
        return actions
    }
}

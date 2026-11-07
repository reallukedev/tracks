import Foundation
import TracksCore

/// Where to start, from launch arguments. Used for screenshots and UI checks, so a given
/// screen can be reached without tapping through the app. Debug builds only.
///
///     -TracksTab charts            Summary, Play, History, Charts or Search (iPhone)
///     -TracksSearch YES            open the Search tab (iPhone)
///     -TracksDemoPlaying YES       with sample data, start the Play tab's first mix (iPhone);
///                                 "station" for Tracks Radio, or a mood such as "chill"
///     -TracksDemoPlaying one       or just its first song, for Autoplay to follow on from
///     -TracksDemoSkips 3           then skip that many songs in a row, a few seconds apart
///     -TracksDemoMoreLikeThis YES  or ask for more like the song on, a few seconds in
///     -TracksNowPlaying YES        open Now Playing once something plays (iPhone)
///     -TracksQueue YES             and show Up Next in it (iPhone), or the panel (Mac)
///     -TracksQualityDetails YES    and open the audio quality badge's details
///     -TracksStage YES             and open Stage (iPhone, from Now Playing), or its window (Mac)
///     -TracksStageControls YES     with its controls up, and kept up
///     -TracksStageCustomize YES    with Customize Stage open
///     -TracksSleeve YES            and turn the cover over to Your History
///     -TracksMix onRepeat          open one of the Play tab's mixes by id (iPhone)
///     -TracksSampleAlbum YES       open an invented Apple Music album page (iPhone)
///     -TracksMood chill            open a mood's page (iPhone)
///     -TracksGenre hip-hop         open a genre's page, by its key
///     -TracksParty YES             open Party, or "dinnerParty" to open it on that party
///     -TracksPartyDelay 60         with sample data, how long Party's playlists take to come
///     -TracksPage songs            open the Song Finder (or "songs.chill" for a lens), the
///                                 Artist Finder ("artists") or New from Your Artists
///                                 ("releases") (iPhone)
///     -TracksCrate 4               start Play's crate that many records from the lead, or back
///                                 with a negative number, into the suggested songs
///     -TracksRadioTuner YES        open Tracks Radio's tuning from its card (iPhone), or
///                                 "queue" from Up Next, with -TracksQueue
///     -TracksSettings play         open Settings at one of its pages: play, history, radio,
///                                 appleMusic, lastFM or iCloud (iPhone)
///     -TracksEditPlay YES          open Edit Play (iPhone)
///     -TracksSidebar history       a sidebar item (Mac): listenNow, radio, summary, history,
///                                 topSongs, playlists, albums and the like
///     -TracksScroll rhythm         a section of Summary to scroll to
///     -TracksOpen "artist:mara solis"   an artist, song:<title>|<artist>,
///                                      or album:<title>|<artist>
///     -TracksSettings YES          open Settings
///     -TracksSearchText "mara"     open Search with this typed (-searchScope history for a scope)
///     -TracksMiniPlayer YES        open the Mini Player too (Mac)
///     -TracksActivate YES          come to the front, so the window is drawn focused (Mac)
///     -statsRange year            the range, since it's stored under that key
///     -TracksPeriodsBack 1         start Summary that many weeks, months or years back
///     -chartSpan day              Top Charts' period: day, week, month, year or allTime
///     -TracksChartDate 2026-09-01  start Top Charts on the period holding this day
///     -separatesMusicSources YES  count Apple Music and Your Music apart, and
///     -statsSourceScope yourMusic show one of them: all, appleMusic or yourMusic
///     -TracksDemoDriving YES       Tracks Radio as if driving
///     -TracksRadioTunerAnchor moments  open the Tune sheet at Time and Driving
///     -TracksRadioTunerAnchor day  open the Tune sheet on Through the Day (iPhone)
///     -TracksThroughTheDayAnchor bottom  scroll Through the Day to its foot
///     -TracksThroughTheDay YES     open Through the Day from the Play pane (Mac)
///     -TracksAppearance light      draw the Mac sheet light whatever the Mac's setting
///     -TracksNearbyDemo YES        a device nearby playing a song, with two seen lately (or
///                                 "paused", "control" to show it in the player, "many" for
///                                 three nearby, "away" for only those seen lately, "none")
///     -TracksDevices YES           open Your Devices
///     -TracksSharePlayDemo host    a pretend SharePlay with sample data (iPhone): "host", or
///                                 "guest" and its states (see SharePlayDemo)
///     -TracksSharePlaySearch "sun" and search for this on the guest page
enum LaunchScene {
    static var tab: String? { value("TracksTab") }
    static var sidebar: String? { value("TracksSidebar") }
    static var scrollAnchor: String? { value("TracksScroll") }
    static var opensSettings: Bool { value("TracksSettings") != nil }
    static var opensDevices: Bool { value("TracksDevices") == "YES" }
    /// The page of Settings to open on, by its name.
    static var settingsPageName: String? { value("TracksSettings") }
    static var opensPlaySettings: Bool { value("TracksSettings") == "play" }
    /// How many weeks, months or years back Summary starts.
    static var periodOffset: Int { -(value("TracksPeriodsBack").flatMap(Int.init).map(abs) ?? 0) }
    static var opensEditPlay: Bool { value("TracksEditPlay") == "YES" }
    static var activates: Bool { value("TracksActivate") == "YES" }
    static var opensSearch: Bool { value("TracksSearch") == "YES" }
    /// Text already in the search field (Mac).
    static var searchText: String? { value("TracksSearchText") }
    static var opensNowPlaying: Bool { value("TracksNowPlaying") == "YES" }
    static var opensQueue: Bool { value("TracksQueue") == "YES" }
    static var opensQualityDetails: Bool { value("TracksQualityDetails") == "YES" }
    static var opensStage: Bool { value("TracksStage") == "YES" }
    /// `-TracksHistoryFilter radio`: History opens filtered, for screenshots.
    static var historyFilter: String? { value("TracksHistoryFilter") }
    static var opensStageControls: Bool { value("TracksStageControls") == "YES" }
    static var opensStageCustomizer: Bool { value("TracksStageCustomize") == "YES" }
    static var opensSleeve: Bool { value("TracksSleeve") == "YES" }
    static var opensRadioTuner: Bool { value("TracksRadioTuner") == "YES" }
    /// Records from the crate's lead to start on.
    static var crateOffset: Int? { value("TracksCrate").flatMap(Int.init) }
    static var opensRadioTunerFromQueue: Bool { value("TracksRadioTuner") == "queue" }
    /// A pretend SharePlay session's scene, with sample data.
    static var sharePlayDemo: String? { value("TracksSharePlayDemo") }
    static var sharePlaySearch: String? { value("TracksSharePlaySearch") }
    /// Opens the SharePlay code's sheet over Now Playing.
    static var opensSharePlayCode: Bool { value("TracksSharePlayCode") == "YES" }
    /// The day Top Charts starts on, as yyyy-MM-dd.
    static var chartDate: Date? {
        value("TracksChartDate").flatMap { try? Date($0, strategy: .iso8601.year().month().day()) }
    }

    static var route: Route? {
        guard let open = value("TracksOpen") else { return nil }
        let parts = open.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "artist":
            return .artist(parts[1])
        case "song":
            let song = parts[1].split(separator: "|").map(String.init)
            guard song.count == 2 else { return nil }
            return .song(HistoryImport.key(title: song[0], artistName: song[1]))
        case "album":
            // Album and artist together, as `CaptureStat.albumIdentity` builds it.
            let album = parts[1].split(separator: "|").map(String.init)
            guard album.count == 2 else { return nil }
            return .album("\(StatsCalculator.folded(album[0]))\u{1F}\(StatsCalculator.folded(album[1]))")
        default:
            return nil
        }
    }

    private static func value(_ key: String) -> String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: key)
        #else
        nil
        #endif
    }
}

extension LaunchScene {
    /// Starts the first mix with sample data, for screenshots of the player. Once per launch.
    /// `-TracksSiriAsk "Blue from my music"`: resolves a spoken request as Siri's would be and
    /// logs what it found, to check matching against the sample library.
    @MainActor
    static func resolveSiriAsk() {
        #if DEBUG
        guard let asked = value("TracksSiriAsk"), !hasResolvedSiriAsk else { return }
        hasResolvedSiriAsk = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            let found = await MediaRequestResolver.item(for: MediaRequest(name: asked))
            print("SiriAsk \"\(asked)\" -> \(found.map { "\($0.identifier) \($0.title) \($0.artist ?? "")" } ?? "nothing")")
        }
        #endif
    }

    @MainActor private static var hasResolvedSiriAsk = false

    @MainActor
    static func startDemoPlayback(_ model: AppModel) {
        resolveSiriAsk()
        guard model.isDemoLaunch, let playing = value("TracksDemoPlaying"), !hasStartedDemoPlayback else { return }
        if playing == "station" {
            hasStartedDemoPlayback = true
            model.player.playTracksRadio()
            skipForDemo(model)
            askForMoreForDemo(model)
            return
        }
        if playing == "local", let album = model.yourMusic.index.recentlyAdded.first {
            hasStartedDemoPlayback = true
            model.player.play(.local(album.tracks), from: PlayContext(kind: .album, title: album.title))
            return
        }
        if let mood = Mood(rawValue: playing) {
            hasStartedDemoPlayback = true
            Task { await MoodPlayback.start(mood, model: model) }
            return
        }
        guard playing == "YES" || playing == "one", let mix = model.playFeed.mixes.rightNow ?? model.playFeed.mixes.mixes.first else { return }
        hasStartedDemoPlayback = true
        let songs = model.player.songs(in: mix)
        model.player.play(.history(playing == "one" ? Array(songs.prefix(1)) : songs), from: PlayContext(kind: .mix, title: mix.kind.title))
        skipForDemo(model)
    }

    /// `-TracksDemoMoreLikeThis`: asks for more like the song on, a few seconds in, as someone
    /// who likes what they hear would from its menu.
    @MainActor
    private static func askForMoreForDemo(_ model: AppModel) {
        guard value("TracksDemoMoreLikeThis") == "YES" else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            model.player.playMoreLikeThis()
        }
    }

    /// `-TracksDemoSkips`: skips that many songs soon after each starts, as someone who isn't
    /// feeling it would, to see a live mix or Autoplay steer.
    @MainActor
    private static func skipForDemo(_ model: AppModel) {
        guard let skips = value("TracksDemoSkips").flatMap(Int.init), skips > 0 else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            for _ in 0..<skips {
                model.player.skipToNext()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    @MainActor private static var hasStartedDemoPlayback = false

    /// Opens the mix named by `-TracksMix` on the Play tab, once its mixes exist.
    @MainActor
    static func openMix(_ model: AppModel) {
        #if DEBUG
        if let name = value("TracksMood"), let mood = Mood(rawValue: name), !hasOpenedMix {
            hasOpenedMix = true
            show(.mood(mood), in: model)
            return
        }
        if let name = value("TracksGenre"), let genre = MusicGenre.all.first(where: { $0.id == name }), !hasOpenedMix {
            hasOpenedMix = true
            show(.genre(genre), in: model)
            return
        }
        if let party = value("TracksParty"), !hasOpenedMix {
            hasOpenedMix = true
            if let vibe = PartyVibe(rawValue: party) {
                UserDefaults.standard.set(vibe.rawValue, forKey: PartyVibe.storageKey)
            }
            show(.party, in: model)
            return
        }
        // `-TracksAlbum "night ferry"` or `-TracksArtist "umbra"`: one of yours, by the start of its name.
        if let name = value("TracksAlbum").map(StatsCalculator.folded), !hasOpenedMix,
           let album = model.yourMusic.index.albums.first(where: { StatsCalculator.folded($0.title).hasPrefix(name) }) {
            hasOpenedMix = true
            // `-TracksDownloadAlbum YES`: and download it, to see downloads come down.
            if value("TracksDownloadAlbum") == "YES" {
                model.yourMusic.downloads.download(album.tracks.filter(\.isFromServer))
            }
            if let page = value("TracksPage"), page == "downloads" {
                show(.yourMusic(.downloads), in: model)
            } else {
                show(.localAlbum(album.id), in: model)
            }
            return
        }
        if let name = value("TracksArtist").map(StatsCalculator.folded), !hasOpenedMix,
           let artist = model.yourMusic.index.artists.first(where: { $0.id.hasPrefix(name) }) {
            hasOpenedMix = true
            show(.localArtist(artist.id), in: model)
            return
        }
        if let page = value("TracksPage"), !hasOpenedMix {
            let parts = page.split(separator: ".").map(String.init)
            let route: PlayRoute? = switch parts.first {
            case "songs": .songFinder(parts.count > 1 ? SongLens.all.first { $0.id == parts[1] || $0.id == "mood.\(parts[1])" } ?? .forYou : .forYou)
            case "artists": .artistFinder
            case "releases": .newReleases
            case "yourSongs": .yourMusic(.songs)
            case "yourAlbums": .yourMusic(.albums)
            case "yourArtists": .yourMusic(.artists)
            case "downloads": .yourMusic(.downloads)
            case "yourPlaylists": .yourMusic(.playlists)
            case "recentlyAdded": .yourMusic(.recentlyAdded)
            case "lidarr": .lidarr
            case "localAlbum": model.yourMusic.index.recentlyAdded.first.map { .localAlbum($0.id) }
            case "localArtist": model.yourMusic.index.artists.first.map { .localArtist($0.id) }
            default: nil
            }
            if let route {
                hasOpenedMix = true
                show(route, in: model)
                return
            }
        }
        if value("TracksSampleAlbum") == "YES", !hasOpenedMix {
            hasOpenedMix = true
            show(.album(PreviewMusic.album()), in: model)
            return
        }
        #endif
        guard let id = value("TracksMix"), !hasOpenedMix, model.playFeed.mixes.mix(id: id) != nil else { return }
        hasOpenedMix = true
        show(.mix(id), in: model)
    }

    @MainActor private static var hasOpenedMix = false

    /// A page on the Play tab on iPhone, or on Listen Now on the Mac, once the window has
    /// moved there: moving to another place clears the stack it pushes onto.
    @MainActor
    private static func show(_ route: PlayRoute, in model: AppModel) {
        model.selectedTab = .play
        guard model.sidebarSelection != .listenNow else {
            model.playNavigator.show(route)
            return
        }
        model.sidebarSelection = .listenNow
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            model.playNavigator.show(route)
        }
    }
}

#if DEBUG
import SwiftUI

extension View {
    /// `-TracksScrollBy 900`: scrolls the page that far down once it's drawn, for screenshots of
    /// what's below the fold. Debug builds only.
    func launchScroll() -> some View {
        modifier(LaunchScroll())
    }
}

private struct LaunchScroll: ViewModifier {
    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        if let offset = UserDefaults.standard.string(forKey: "TracksScrollBy").flatMap(Double.init) {
            content
                .scrollPosition($position)
                .task {
                    try? await Task.sleep(for: .seconds(UserDefaults.standard.string(forKey: "TracksScrollDelay").flatMap(Double.init) ?? 4))
                    position.scrollTo(y: offset)
                }
        } else {
            content
        }
    }
}
#else
import SwiftUI

extension View {
    func launchScroll() -> some View { self }
}
#endif

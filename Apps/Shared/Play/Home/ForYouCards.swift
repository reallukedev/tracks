import SwiftUI
import MusicKit
import TracksCore

/// One of the records in the crate at the top of Play: the mix for this hour, Tracks Radio,
/// Discover, and the mixes for the rest of the day, with suggested songs going on past them
/// either way. See ``Crate``.
enum ForYouCard: Identifiable {
    case mix(Mix)
    case station
    case discover([Song])
    /// A song suggested for you, past the mixes.
    case song(CrateSong)

    var id: String {
        switch self {
        case .mix(let mix): mix.id
        case .station: "station"
        case .discover: "discover"
        case .song(let song): song.id
        }
    }

    var isSong: Bool {
        if case .song = self { return true }
        return false
    }
}

/// A suggested song in the crate: one from Apple Music you've never played, or one of your
/// own, from a server's finds or your music waiting to be heard.
struct CrateSong: Identifiable, Equatable {
    enum Kind: Equatable {
        case catalog(Suggestion)
        case local(LocalTrack)
    }

    let kind: Kind
    let cover: CoverArt
    /// Why it's here, in a few words, over its name: "Because you like Nova Harbor".
    let reason: String

    var id: String {
        switch kind {
        case .catalog(let suggestion): "song.\(suggestion.id.rawValue)"
        case .local(let track): "local.\(track.id)"
        }
    }

    var title: String {
        switch kind {
        case .catalog(let suggestion): suggestion.song.title
        case .local(let track): track.title
        }
    }

    var artistName: String {
        switch kind {
        case .catalog(let suggestion): suggestion.song.artistName
        case .local(let track): track.artist
        }
    }

    /// The song as the history knows it, for telling whether it's the one playing.
    var identity: String {
        switch kind {
        case .catalog(let suggestion): suggestion.identity
        case .local(let track): track.identity
        }
    }

    init(_ suggestion: Suggestion) {
        kind = .catalog(suggestion)
        cover = suggestion.song.artwork.map(CoverArt.artwork) ?? .url(nil, seed: suggestion.song.albumTitle ?? suggestion.song.title)
        reason = suggestion.reason.rowLine(for: suggestion.song)
    }

    init(_ track: LocalTrack, reason: String, music: YourMusic) {
        kind = .local(track)
        cover = .url(music.artworkURL(track.artwork)?.absoluteString, seed: track.album ?? track.title)
        self.reason = reason
    }
}

/// The crate, with songs suggested for you going on past the mixes either way, from wherever
/// suggestions come from for the music playing: Apple Music's through Discovery; with your
/// own music, what your servers find beyond their shelves, or with suggestions off or no
/// server, your own songs waiting to be heard.
struct ForYouCrate: View {
    let cards: [ForYouCard]
    let leadID: String?

    @Environment(AppModel.self) private var model
    @Environment(Discovery.self) private var discovery
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @AppStorage(SuggestionMode.storageKey) private var mode = SuggestionMode.everything
    @AppStorage(PlayPreferences.layoutKey) private var storedLayout = ""
    /// Your own songs waiting to be heard, worked out when your music or history changes.
    @State private var waiting: [LocalTrack] = []
    /// How many of them the crate has reached.
    @State private var waitingReach = Self.page

    private static let page = 16

    var body: some View {
        let supply = supply
        let blocked = player.signals.blocked
        Crate(
            cards: cards,
            leadID: leadID,
            // Whoever the suggestions came from, none by someone blocked.
            songs: supply.songs.filter { !blocked.blocks(songBy: $0.artistName) },
            songsGoOn: supply.goesOn,
            songsGeneration: supply.generation,
            loadMoreSongs: supply.loadMore
        )
        .task(id: WaitingKey(songs: music.index.tracks.count, history: feed.builtRevision)) {
            guard model.musicSource == .yourMusic else { return }
            waiting = waitingToBeHeard()
        }
    }

    private struct Supply {
        var songs: [CrateSong] = []
        var goesOn = false
        var generation = 0
        var loadMore: (() async -> Void)?
    }

    private struct WaitingKey: Equatable {
        let songs: Int
        let history: Int?
    }

    private var supply: Supply {
        if model.musicSource == .appleMusic { return catalog }
        // Sample data stands in for a server with the sample catalog, as its shelves do.
        if player.isDemo, mode != .off { return catalog }
        let servers = music.servers.onlineServers.filter { music.discover.forYou[$0.id] != nil }
        if mode != .off, !servers.isEmpty { return fromServers(servers) }
        return fromYourMusic
    }

    /// Discovery's songs, walking out from your artists for more as the ends near. With your
    /// own music, only the ones it has, or with Everything, can get.
    private var catalog: Supply {
        let source = model.musicSource
        // Past the first page of Suggested Songs just below, so the two never show the same
        // songs at once.
        let skipped = PlayLayout(stored: storedLayout).isVisible(.suggestedSongs) ? Discovery.shelfPage : 0
        let visible = discovery.songs.visible(in: music, source: source, mode: mode).dropFirst(skipped)
        let unanswered = discovery.songs.unanswered(in: music, source: source)
        let (discovery, music, mode) = (discovery, music, mode)
        var generation = Hasher()
        // Answers that left nothing new to show change it too, so the crate asks again.
        generation.combine(discovery.expansions)
        generation.combine(music.availabilityGeneration)
        generation.combine(unanswered)
        return Supply(
            songs: visible.map(CrateSong.init),
            goesOn: discovery.canExpand || unanswered > 0,
            generation: generation.finalize(),
            loadMore: {
                // A page's worth to show: songs your servers don't have are left out, so it
                // looks up, and walks further out, until there are, or there's nothing left.
                await SuggestionPaging.fill(
                    want: Self.page,
                    maxSteps: 6,
                    count: { discovery.songs.visible(in: music, source: source, mode: mode).count }
                ) {
                    if discovery.songs.unanswered(in: music, source: source) > 0 {
                        await discovery.songs.lookUp(in: music, source: source, mode: mode, first: 12)
                        return true
                    }
                    guard discovery.canExpand, !discovery.expandFailed else { return false }
                    await discovery.expand()
                    return !discovery.expandFailed
                }
            }
        )
    }

    /// More songs your servers find by artists new to you, none of them on Play's shelves: the
    /// same song on two servers comes once.
    private func fromServers(_ servers: [SubsonicServer]) -> Supply {
        let found = SuggestionPaging.new(
            servers.flatMap { music.discover.forYou[$0.id].map(\.further) ?? [] },
            known: [String](),
            by: \.identity
        )
        let goingOn = servers.filter { server in
            music.discover.forYou[server.id].map { $0.isFilling || $0.canGoOn } ?? false
        }
        // Each answer counts, even one that found nothing, so the crate asks again.
        let answers = servers.reduce(0) { $0 &+ (music.discover.answers[$1.id] ?? 0) }
        let music = music
        return Supply(
            songs: found.map { CrateSong($0, reason: String(localized: "New to You"), music: music) },
            goesOn: !goingOn.isEmpty,
            generation: found.count &+ answers,
            loadMore: {
                // Each server in turn, so one that's found all it can doesn't hold up the rest.
                guard !goingOn.isEmpty else { return }
                let server = goingOn[answers % goingOn.count]
                await music.discover.loadMore(for: server.id, shelf: .further, want: Self.page / 2)
            }
        )
    }

    /// Your own songs you've never played, then the ones you've played least lately.
    private var fromYourMusic: Supply {
        let reached = waiting.prefix(waitingReach)
        let music = music
        return Supply(
            songs: reached.map { track in
                CrateSong(track, reason: feed.facts[track.identity] == nil ? String(localized: "Waiting to Be Heard") : String(localized: "From Your Music"), music: music)
            },
            goesOn: waiting.count > waitingReach,
            generation: waitingReach,
            loadMore: { waitingReach += Self.page }
        )
    }

    private func waitingToBeHeard() -> [LocalTrack] {
        let playable = music.index.tracks.filter { music.isPlayable($0) }
        return FreshShuffle.order(
            playable,
            artist: \.artistKey,
            recentlyHeard: { feed.facts[$0.identity] != nil },
            seed: FreshShuffle.dailySeed(for: .now, salt: "crate.waiting")
        )
    }
}

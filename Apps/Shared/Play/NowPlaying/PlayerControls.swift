import SwiftUI
import MusicKit
import TracksCore

/// Where Now Playing can send the person, after it has closed.
enum NowPlayingDestination {
    case play(PlayRoute)
    case stats(Route)
}

/// Previous, play or pause, and next, big enough for a thumb. They answer the moment they're
/// touched, as Music's do: the glyph sinks under the finger with a soft circle behind it, play
/// and pause turn into each other straight away, and the skip arrows slide on.
struct PlayerTransport: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousTaps = 0
    @State private var nextTaps = 0
    @State private var playTaps = 0

    var body: some View {
        HStack {
            Button {
                previousTaps += 1
                player.skipToPrevious()
            } label: {
                SkipArrows(direction: .backward, height: 26, trigger: previousTaps)
            }
            .buttonStyle(PlayerButtonStyle(diameter: 76))
            .disabled(player.context?.isStation == true)
            .accessibilityLabel("Previous")

            Spacer()

            Button {
                playTaps += 1
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .replace.downUp)))
            }
            .buttonStyle(PlayerButtonStyle(diameter: 88))
            .overlay {
                if player.isPlaying, player.status == .loading {
                    TurningRing(diameter: 84, lineWidth: 2.5, color: .primary.opacity(0.5))
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: player.status == .loading)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityValue(player.isPlaying && player.status == .loading ? Text("Loading") : Text(""))

            Spacer()

            Button {
                nextTaps += 1
                player.skipToNext()
            } label: {
                SkipArrows(direction: .forward, height: 26, trigger: nextTaps)
            }
            .buttonStyle(PlayerButtonStyle(diameter: 76))
            .accessibilityLabel("Next")
        }
        .padding(.horizontal, 16)
        // Each press felt as the button gives: firmer for play and pause, the one that
        // changes what you hear.
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: playTaps)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: previousTaps)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: nextTaps)
    }
}

/// Press in fast, spring back out: a finger on the glass should feel the button give at once,
/// and let go with a little life.
struct PlayerButtonStyle: ButtonStyle {
    var diameter: CGFloat = 76
    var highlight: Color = .white
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(highlight.opacity(isEnabled ? 1 : 0.35))
            .scaleEffect(pressed && !reduceMotion ? 0.84 : 1)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(highlight.opacity(0.14))
                    .scaleEffect(pressed ? 1 : 0.55)
                    .opacity(pressed ? 1 : 0)
            }
            .contentShape(.circle)
            .animation(pressed ? .easeOut(duration: 0.07) : .spring(duration: 0.42, bounce: 0.42), value: pressed)
    }
}

/// Music's skip arrows. On a press the front arrow shrinks away into its point, the one
/// behind slides into its place, and a new one grows in behind it, in one quick spring, so the
/// glyph steps the way it skips and settles looking as it did. Back is the same, mirrored.
/// Each arrow is the system's play triangle, so the weight matches the play button beside it.
/// Still under Reduce Motion.
struct SkipArrows: View {
    enum Direction { case forward, backward }

    let direction: Direction
    /// The arrows' height. Two of them side by side are a little wider than this.
    let height: CGFloat
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let arrow = height * 0.86
        Group {
            if reduceMotion {
                arrows(step: 1, arrow: arrow)
            } else {
                KeyframeAnimator(initialValue: 1.0, trigger: trigger) { step in
                    arrows(step: step, arrow: arrow)
                } keyframes: { _ in
                    KeyframeTrack {
                        // From the resting pose, one step, springing into place.
                        MoveKeyframe(0)
                        SpringKeyframe(1, duration: 0.38, spring: .init(response: 0.34, dampingRatio: 0.78))
                    }
                }
            }
        }
        .frame(width: arrow * 2, height: height, alignment: .leading)
        .scaleEffect(x: direction == .forward ? 1 : -1)
        .accessibilityHidden(true)
    }

    /// The glyph part way through its step: 0 and 1 are both the resting pose.
    private func arrows(step: Double, arrow: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Growing in behind, from its base.
            triangle(arrow)
                .scaleEffect(max(step, 0.001), anchor: .leading)
                .opacity(step)
            // Sliding up into the front.
            triangle(arrow)
                .offset(x: arrow * step)
            // Shrinking away into its point.
            triangle(arrow)
                .scaleEffect(max(1 - step, 0.001), anchor: .trailing)
                .opacity(1 - step)
                .offset(x: arrow)
        }
    }

    private func triangle(_ width: CGFloat) -> some View {
        Image(systemName: "play.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: width, height: height)
    }
}

/// Tracks’ line under the song: how often you've heard it, rolling up the moment it's kept.
struct PlayCountLine: View {
    let track: PlayerTrack
    /// "since August" after the count. Left off where there's only room for the count.
    var showsSince = true
    @Environment(PlayFeed.self) private var feed
    @Environment(PlayerModel.self) private var player
    @Environment(CaptureService.self) private var capture
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let facts = feed.facts(for: track)
        let plays = facts?.plays ?? 0
        HStack(spacing: 6) {
            if willBeKept, !isPassedOver {
                KeepIndicator(track: track, isKept: isKept)
            }
            if plays == 0 {
                Text("First listen")
            } else {
                Text("^[\(plays) play](inflect: true)")
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(plays)))
                if showsSince, let first = facts?.firstHeard {
                    Text(verbatim: "·")
                    Text(Self.since(first))
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: plays)
        .accessibilityElement(children: .combine)
    }

    private var willBeKept: Bool { KeepStatus.willBeKept(player: player, capture: capture) }
    private var isKept: Bool { KeepStatus.isKept(track, player: player, capture: capture) }
    private var isPassedOver: Bool { KeepStatus.isPassedOver(track, player: player, capture: capture) }

    /// "since March 2024", or "since today".
    private static func since(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return String(localized: "since today") }
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let when = sameYear ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.abbreviated).year())
        return String(localized: "since \(when)")
    }
}

/// The song's menu: where it's from, what to do with it, and the sleep timer.
struct NowPlayingMenu: View {
    let track: PlayerTrack
    let onNavigate: (NowPlayingDestination) -> Void
    @Environment(\.openRadioTuner) private var openRadioTuner

    var body: some View {
        Menu {
            #if os(iOS)
            // At the top, where Music has it.
            SharePlayMenuItem()
            Button("Stage", systemImage: "tv") { StagePresenter.shared.isShowing = true }
            SleepTimerMenu()
            Divider()
            // The star beside the controls has Favorite.
            NowPlayingMenuItems(track: track, onNavigate: onNavigate, onTuneRadio: openRadioTuner.map { open in { open() } }, showsFavorite: false)
            #else
            NowPlayingMenuItems(track: track, onNavigate: onNavigate, onTuneRadio: openRadioTuner.map { open in { open() } })
            #endif
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.15), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .accessibilityLabel("More")
    }
}

/// The playing song's actions, for its menu on iPhone and its context menu on the Mac.
struct NowPlayingMenuItems: View {
    let track: PlayerTrack
    /// Where Go to Album and the like lead. Nil pushes onto the stack the view is in.
    var onNavigate: ((NowPlayingDestination) -> Void)?
    /// Opens Tracks Radio's tuning, where the menu can show it. Nil leaves Tune out.
    var onTuneRadio: (() -> Void)?
    /// False where Favorite has a button of its own.
    var showsFavorite = true
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        if let local = track.local {
            LocalTrackMenu(track: local, onNavigate: { navigate(.play($0)) }, showsStats: true, adjust: addNowPlaying)
        } else {
            SongMenuItems(actions)
        }
    }

    private var actions: SongActions {
        var actions = if let song = track.song {
            SongActions.catalog(song, player: player, go: { navigate(.play($0)) })
        } else {
            // The demo's songs, known by name alone.
            SongActions(suggestLess: track.songIdentity, block: track.artistName)
        }
        addNowPlaying(&actions)
        if !showsFavorite { actions.favorite = nil }
        return actions
    }

    /// What the playing song's menu has beyond any song's: stats on your stats' own stack,
    /// steering a live mix, and tuning Tracks Radio.
    private func addNowPlaying(_ actions: inout SongActions) {
        let identity = track.songIdentity
        // It's already playing, or already queued.
        actions.playNext = nil
        actions.playLast = nil
        actions.stats = { navigate(.stats(.song(identity))) }
        actions.info = SongInfoSubject(track)
        // Steering what a live mix plays next, for the song on only.
        if player.canAskForMoreLikeThis, identity == player.current?.songIdentity {
            let isAsked = player.moreLikeThis.contains(identity)
            let title: LocalizedStringKey = isAsked ? "Asked for More Like This" : "Play More Like This"
            actions.steer.append(SongMenuButton(title: title, systemImage: isAsked ? "hand.thumbsup.fill" : "hand.thumbsup", isDisabled: isAsked) {
                player.playMoreLikeThis()
            })
        }
        if let onTuneRadio, player.isPlayingTracksRadio, identity == player.current?.songIdentity {
            actions.trailing.append(SongMenuButton(title: "Tune Tracks Radio…", systemImage: "slider.horizontal.3", action: onTuneRadio))
        }
    }

    private func navigate(_ destination: NowPlayingDestination) {
        if let onNavigate {
            onNavigate(destination)
            return
        }
        switch destination {
        case .play(let route): openPlayRoute(route)
        case .stats(let route): openPlayRoute(.stats(route))
        }
    }
}

/// The sleep timer as a submenu, for the player's More menu. Says the time left while it runs.
struct SleepTimerMenu: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Menu {
            SleepTimerItems(player: player)
        } label: {
            Label("Sleep Timer", systemImage: player.sleepTimer == nil ? "moon.zzz" : "moon.zzz.fill")
            if let remaining {
                Text(remaining)
            }
        }
    }

    private var remaining: String? {
        guard let timer = player.sleepTimer else { return nil }
        if timer == .endOfSong { return String(localized: "End of Song") }
        guard let left = player.sleepRemaining(at: .now) else { return nil }
        return String(localized: "\(Scrubber.format(left)) left")
    }
}

/// The sleep timer's choices: the end of the song, or a quarter of an hour to an hour. Given
/// the player, since the Mac's menu bar has no environment to read it from.
struct SleepTimerItems: View {
    let player: PlayerModel

    var body: some View {
        if player.sleepTimer != nil {
            Button("Turn Off Timer", systemImage: "xmark") { player.setSleepTimer(nil) }
            Divider()
        }
        Button("End of Song") { player.setSleepTimer(.endOfSong) }
        ForEach(SleepTimer.durations, id: \.self) { duration in
            Button(duration.formatted(.units(allowed: [.hours, .minutes], width: .wide))) {
                player.setSleepTimer(.at(.now.addingTimeInterval(TimeInterval(duration.components.seconds))))
            }
        }
    }
}

/// A ring that fills as a song plays, until it has played long enough for Tracks to keep it,
/// then turns into a check. Shows how close a song is to counting without a number to read.
struct KeepIndicator: View {
    let track: PlayerTrack
    let isKept: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnScreen) private var isOnScreen
    @ScaledMetric(relativeTo: .subheadline) private var side: CGFloat = 15

    var body: some View {
        // Still while the song loads: it counts once it's really playing. Once a second is
        // enough for a ring this small, and it shows in the bar's panel and the menu bar too.
        TimelineView(.animation(minimumInterval: 1, paused: isKept || player.status != .playing || !isOnScreen)) { context in
            let progress = progress(at: context.date)
            // With sample data nothing is kept, so a full ring stands in for it.
            let kept = isKept || (player.isDemo && progress >= 1)
            ZStack {
                if kept {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                } else {
                    Circle()
                        .stroke(.tertiary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: side, height: side)
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: kept)
            .accessibilityElement()
            .accessibilityLabel(kept ? Text("Kept in your history") : Text("Counting toward your history"))
        }
    }

    private func progress(at date: Date) -> Double {
        KeepStatus.progress(player: player, at: date)
    }
}

/// The song's name and artist on the player, as a menu of where they lead, as Music's are:
/// its album, its artist, and your stats for it.
struct NowPlayingTitleMenu<Label: View>: View {
    let track: PlayerTrack
    let onNavigate: (NowPlayingDestination) -> Void
    @ViewBuilder let label: () -> Label
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @Environment(\.showSongInfo) private var showSongInfo

    var body: some View {
        let actions = actions
        Menu {
            if let goToAlbum = actions.goToAlbum {
                Button("Go to Album", systemImage: "square.stack", action: goToAlbum)
            }
            GoToArtistItem(actions: actions)
            if let stats = actions.stats {
                Button("Your Stats", systemImage: "chart.bar.xaxis", action: stats)
            }
            if let showSongInfo {
                Button("Get Info", systemImage: "info.circle") { showSongInfo(SongInfoSubject(track)) }
            }
        } label: {
            label()
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityHint("Shows the album, the artist, your stats and the song's info")
    }

    private var actions: SongActions {
        let go: (PlayRoute) -> Void = { onNavigate(.play($0)) }
        var actions: SongActions
        if let local = track.local {
            actions = .local(local, music: music, player: player, go: go)
        } else if let song = track.song {
            actions = .catalog(song, player: player, go: go)
        } else {
            // Known by name alone, as the demo's songs are: your history's pages for them.
            let credits = ArtistCredits.song(artist: track.artistName, title: track.title)
            let artist = credits.first?.identity ?? StatsCalculator.folded(track.artistName)
            let lead = credits.first?.name ?? track.artistName
            actions = SongActions()
            if let album = track.albumTitle.map(StatsCalculator.folded), !album.isEmpty {
                actions.goToAlbum = { onNavigate(.stats(.album("\(album)\u{1F}\(artist)"))) }
            }
            actions.goToArtist = { go(.artistNamed(lead, identity: artist)) }
            actions.linkArtists(credits) { go(.artistNamed($0.name, identity: $0.identity)) }
        }
        let identity = track.songIdentity
        actions.stats = { onNavigate(.stats(.song(identity))) }
        return actions
    }
}

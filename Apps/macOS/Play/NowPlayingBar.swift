import SwiftUI
import AVKit
import TracksCore

extension View {
    /// The song playing, on a glass bar floating at the foot of the page, as the iPhone's
    /// player floats above its tabs. There only while something is queued; pages scroll
    /// under it and end above it.
    func nowPlayingBar() -> some View {
        modifier(NowPlayingBarPlacement())
    }
}

/// What the main window shows around its pages: the panel beside them and the full player
/// over them. Each window has its own, read by every page for its bar.
@MainActor
@Observable
final class PlayerWindowState {
    var showsPanel = LaunchScene.opensQueue
    var panelPage = PlayerPanelPage.upNext
    var showsFullPlayer = LaunchScene.opensNowPlaying
    /// The full player's own Up Next, in place of the song's details.
    var fullPlayerShowsUpNext = false
    /// The full player's sleeve turned over to your history with the song.
    var fullPlayerShowsHistory = LaunchScene.opensSleeve
    /// The window's pages in the order they appeared, the one in front last. A page pushed
    /// over another doesn't make it disappear, so this is how the one under knows.
    private(set) var pages: [UUID] = []

    func pageAppeared(_ page: UUID) {
        pages.removeAll { $0 == page }
        pages.append(page)
    }

    func pageDisappeared(_ page: UUID) {
        pages.removeAll { $0 == page }
    }

    /// Whether `page` is showing, in the full player while it's up or the bar's popover.
    func isShowing(_ page: PlayerPanelPage, inFullPlayer: Bool) -> Bool {
        guard inFullPlayer else { return showsPanel && panelPage == page }
        switch page {
        case .upNext: return fullPlayerShowsUpNext
        case .history: return fullPlayerShowsHistory
        }
    }

    /// Shows `page`, or hides it if it's showing: in the full player while it's up, since it
    /// covers the bar the popover rises from.
    func toggle(_ page: PlayerPanelPage, inFullPlayer: Bool) {
        guard inFullPlayer else {
            if showsPanel, panelPage == page {
                showsPanel = false
            } else {
                panelPage = page
                showsPanel = true
            }
            return
        }
        switch page {
        case .upNext: fullPlayerShowsUpNext.toggle()
        case .history: fullPlayerShowsHistory.toggle()
        }
    }
}

/// Every page of the main window wears the bar itself: a page pushed onto the window's stack
/// takes the column's place, so a bar laid over the stack would go with it.
private struct NowPlayingBarPlacement: ViewModifier {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @Environment(PlayerWindowState.self) private var window: PlayerWindowState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnScreen) private var isOnScreen
    @State private var page = UUID()

    func body(content: Content) -> some View {
        if let window {
            placed(content, window: window)
        } else {
            content
        }
    }

    private func placed(_ content: Content, window: PlayerWindowState) -> some View {
        @Bindable var window = window
        // A page with another pushed over it stays, hidden, with its bar: it and everything
        // on it rest until it's in front again.
        let isInFront = window.pages.last.map { $0 == page } ?? true
        let remote = model.controlledDevice
        let isPresented = player.hasQueue || remote != nil
        let showsPanel = $window.showsPanel
        let panelPage = $window.panelPage
        // A bar of the page's safe area, so pages end above it and the scroll edge effect
        // softens what passes under it: song titles don't read through the glass.
        return content
            .safeAreaBar(edge: .bottom) {
                Group {
                    if let remote {
                        // Another device's song, controlled from here, as Spotify Connect does.
                        RemoteNowPlayingBar(device: remote)
                    } else if player.hasQueue {
                        NowPlayingBar(showsPanel: showsPanel, panelPage: panelPage)
                    }
                }
                .padding(.horizontal, NowPlayingBar.margin)
                .padding(.bottom, NowPlayingBar.margin)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            .animation(reduceMotion ? nil : PlayMotion.panel, value: isPresented)
            .animation(reduceMotion ? nil : PlayMotion.panel, value: remote?.id)
            .environment(\.isOnScreen, isOnScreen && isInFront)
            .onAppear { window.pageAppeared(page) }
            .onDisappear { window.pageDisappeared(page) }
    }
}

/// The bar while it's showing another device's song: the same player, its controls sent
/// there, with where it's playing said in the accent, and the way to bring it here or give the
/// bar back to this Mac.
private struct RemoteNowPlayingBar: View {
    let device: NearbyDevices.Device
    @Environment(AppModel.self) private var model
    @State private var isMoving = false

    var body: some View {
        let state = device.state ?? NearbyState()
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                CoverImage(cover: .url(state.artworkURL, seed: state.album ?? state.title ?? device.name), size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title ?? "")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Label {
                        Text("Playing on \(device.name)")
                    } icon: {
                        Image(systemName: device.kind.symbol)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                }
            }
            .padding(6)
            .frame(minWidth: 170, idealWidth: 230, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 3) {
                RemoteTransport(device: device, state: state)
                RemoteScrubber(device: device, state: state, showsTimes: false)
                    .frame(width: 220, height: 8)
            }

            HStack(spacing: 2) {
                Button {
                    Task {
                        isMoving = true
                        _ = await model.playHere(from: device)
                        isMoving = false
                    }
                } label: {
                    if isMoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Play on This Mac", systemImage: "laptopcomputer")
                            .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(BarIconButtonStyle(diameter: 30))
                .help("Play on This Mac, from where it's got to")
                Button {
                    model.control(nil)
                } label: {
                    Label("Stop Controlling \(device.name)", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(BarIconButtonStyle(diameter: 30))
                .help("Show This Mac's Player")
            }
            .frame(minWidth: 170, idealWidth: 230, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: NowPlayingBar.height)
        .frame(maxWidth: NowPlayingBar.maxWidth)
        .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .capsule)
        .frame(maxWidth: .infinity)
    }
}

/// The song playing, on a glass capsule at the foot of the page, as the iPhone's player
/// floats above its tabs: the song on the left, which opens the full player, as the iPhone's
/// does; the transport in the middle with the song's progress under it; Up Next, your history
/// with the song and AirPlay on the right, the first two in a popover rising from the bar.
struct NowPlayingBar: View {
    @Binding var showsPanel: Bool
    @Binding var panelPage: PlayerPanelPage
    @Environment(PlayerModel.self) private var player
    @Environment(\.openFullPlayer) private var openFullPlayer
    @Environment(YourMusic.self) private var music
    @Environment(\.openRadioTuner) private var openRadioTuner
    @State private var isDropTarget = false
    @State private var room = Room()

    static let margin: CGFloat = 14
    static let height: CGFloat = 64
    /// As wide as it reads well: on a large display it stays a player, not a ribbon.
    static let maxWidth: CGFloat = 900

    var body: some View {
        if let track = player.current {
            let tier = player.sleepTimer == nil ? room.tier : room.tierWithTimer
            Group {
                if tier == .mini {
                    miniBar(track)
                } else {
                    bar(track, tier: tier)
                }
            }
            // Its width comes from the page, never from what's in it, so the tier it measures
            // can't change the width it was measured at.
            .frame(minWidth: 0, maxWidth: Self.maxWidth)
            .frame(height: Self.height)
            .onGeometryChange(for: Room.self) { proxy in
                Room(width: proxy.size.width)
            } action: { room = $0 }
            .glassEffect(.regular, in: .capsule)
            .overlay {
                if isDropTarget {
                    Capsule()
                        .strokeBorder(.tint, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            // Up Next and your history rise from the bar's right end, as iTunes's Up Next did.
            .popover(isPresented: $showsPanel, attachmentAnchor: .point(UnitPoint(x: 0.93, y: 0)), arrowEdge: .top) {
                PlayerPanel(page: $panelPage)
                    .frame(width: PlayerPanel.width, height: 560)
            }
            // Songs dragged onto the player play after everything queued.
            .dropDestination(for: SongDrag.self) { drops, _ in
                Task {
                    for drop in drops {
                        guard let request = await drop.request(in: music) else { continue }
                        player.enqueue(request, next: false, title: drop.title)
                    }
                }
                return !drops.isEmpty
            } isTargeted: { isDropTarget = $0 }
            .animation(PlayMotion.hover, value: isDropTarget)
            .frame(maxWidth: .infinity)
            .contextMenu {
                NowPlayingMenuItems(track: track, onTuneRadio: openRadioTuner.map { open in { open() } })
            }
        }
    }

    /// Four widths: everything, then without shuffle and repeat, then without the times, then
    /// the song and play alone for a narrow window. Only the one with room is built, since each
    /// carries a ticking progress line.
    private nonisolated enum Tier { case full, medium, compact, mini }

    /// The tiers the bar's width has room for, with and without the sleep timer's time beside
    /// the panel buttons. The same across most widths, so resizing seldom redraws the bar.
    private nonisolated struct Room: Equatable {
        var tier = Tier.full
        var tierWithTimer = Tier.full

        init() {}

        /// From the columns' fixed widths: the sides (250, or 190 below full), the progress line
        /// (300, or 200 compact) and the padding round them.
        init(width: CGFloat) {
            tier = Self.tier(for: width, timer: 0)
            tierWithTimer = Self.tier(for: width, timer: 40)
        }

        private static func tier(for width: CGFloat, timer: CGFloat) -> Tier {
            if width >= 840 { return .full }
            if width >= 720 + timer { return .medium }
            if width >= 620 { return .compact }
            return .mini
        }
    }

    private func miniBar(_ track: PlayerTrack) -> some View {
        HStack(spacing: 6) {
            BarSong(track: track, coverSize: 40, action: { openFullPlayer() })
                .frame(minWidth: 120, idealWidth: 150, maxWidth: .infinity, alignment: .leading)
            BarTransport(showsPrevious: false)
            PanelToggle(page: .upNext, systemImage: "list.bullet", title: "Up Next", shortcut: "⌥⌘U", showsPanel: $showsPanel, current: $panelPage)
        }
        .padding(.horizontal, 8)
    }

    /// Three columns, the outer two the same width so the transport sits in the middle.
    private func bar(_ track: PlayerTrack, tier: Tier) -> some View {
        let canShuffle = tier == .full && player.context?.isStation != true && !player.isLive
        let side: CGFloat = tier == .full ? 250 : 190
        return HStack(spacing: 0) {
            BarSong(track: track, coverSize: 46, action: { openFullPlayer() })
                .frame(minWidth: side, idealWidth: side, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 1) {
                HStack(spacing: 6) {
                    if canShuffle { ShuffleButton() }
                    BarTransport()
                    if canShuffle { RepeatButton() }
                }
                if let duration = track.duration, duration > 0 {
                    BarProgress(duration: duration, showsTimes: tier != .compact)
                        .frame(width: tier == .compact ? 200 : 300)
                } else {
                    Text("Live")
                        .font(.caption2.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .frame(height: 12)
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 2) {
                if player.sleepTimer != nil {
                    BarSleepTimer()
                }
                PanelToggle(page: .history, systemImage: "clock.arrow.circlepath", title: "Your History", shortcut: "⌥⌘Y", showsPanel: $showsPanel, current: $panelPage)
                PanelToggle(page: .upNext, systemImage: "list.bullet", title: "Up Next", shortcut: "⌥⌘U", showsPanel: $showsPanel, current: $panelPage)
                if tier != .compact {
                    StageBarButton()
                    RoutePickerButton()
                        .frame(width: 30, height: 30)
                        .help("AirPlay")
                }
            }
            .padding(.trailing, 8)
            .frame(minWidth: side, idealWidth: side, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
    }
}

/// The song, which opens the full player. Under the pointer it says so: a soft highlight
/// gathers behind it, the cover lifts, and a chevron rises beside the title.
private struct BarSong: View {
    let track: PlayerTrack
    let coverSize: CGFloat
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Between the cover and the highlight's edge.
    private static let inset: CGFloat = 5

    /// The highlight's corners follow the cover's, the inset out, rather than rounding off
    /// into a capsule the square cover sits awkwardly in.
    private var highlight: RoundedRectangle {
        RoundedRectangle(cornerRadius: CoverImage.radius(for: coverSize) + Self.inset, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                CoverImage(cover: track.cover, size: coverSize)
                    .shadow(color: .black.opacity(isHovering ? 0.3 : 0.15), radius: isHovering ? 6 : 2, y: isHovering ? 3 : 1)
                    .scaleEffect(isHovering && !reduceMotion ? 1.05 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(track.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if track.isExplicit {
                            ExplicitBadge()
                        }
                    }
                    // The quality beside the artist, as Music's player shows Lossless; the
                    // artist gives way first in a narrow bar.
                    HStack(spacing: 5) {
                        Text(track.artistName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        AudioQualityBadge(track: track, style: .bar)
                            .fixedSize()
                    }
                }
                .layoutPriority(-1)
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                    .offset(y: isHovering || reduceMotion ? 0 : 4)
            }
            .padding(Self.inset)
            .padding(.trailing, 7)
            .background {
                highlight.fill(.primary.opacity(isHovering ? 0.08 : 0))
            }
            .contentShape(highlight)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.2)) { isHovering = hovering }
        }
        .help("Show Full Player (⇧⌘F)")
        .accessibilityLabel(Text("\(track.title), \(track.artistName)"))
        .accessibilityHint("Shows the full player")
    }
}

/// The song's progress under the transport: the times either side of a hairline that
/// thickens under the pointer, to click or drag.
private struct BarProgress: View {
    let duration: TimeInterval
    let showsTimes: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(\.isOnScreen) private var isOnScreen
    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        // Once a second, as the times change. Every tick lays the window out again.
        TimelineView(.animation(minimumInterval: 1, paused: !player.isPlaying || dragFraction != nil || !isOnScreen)) { _ in
            let fraction = dragFraction ?? min(1, max(0, player.playbackTime / duration))
            HStack(spacing: 6) {
                if showsTimes {
                    time(fraction * duration)
                }
                GeometryReader { proxy in
                    let isActive = isHovering || dragFraction != nil
                    ZStack(alignment: .leading) {
                        // Strong enough to read on the glass over any colour.
                        Capsule().fill(.primary.opacity(0.22))
                        Capsule()
                            .fill(.primary.opacity(isActive ? 0.9 : 0.7))
                            .offset(x: -proxy.size.width * (1 - fraction))
                    }
                    .frame(height: isActive ? 6 : 4)
                    .clipShape(.capsule)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .onHover { isHovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            }
                            .onEnded { _ in
                                if let dragFraction { player.seek(to: dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.13), value: isActive)
                }
                if showsTimes {
                    time(max(0, duration - fraction * duration), isRemaining: true)
                }
            }
            .frame(height: 12)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Text("\(Scrubber.format(fraction * duration)) of \(Scrubber.format(duration))"))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 15 : -15
                player.seek(to: min(duration, max(0, fraction * duration + step)))
            }
        }
    }

    private func time(_ seconds: TimeInterval, isRemaining: Bool = false) -> some View {
        // Sized by the song's longest time with the ticking one drawn over it, so the bar's
        // size never changes and its widths aren't all measured again every second.
        Text(verbatim: (isRemaining ? "-" : "") + Scrubber.format(duration))
            .hidden()
            .overlay(alignment: isRemaining ? .leading : .trailing) {
                Text(verbatim: (isRemaining ? "-" : "") + Scrubber.format(seconds))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 32, alignment: isRemaining ? .leading : .trailing)
    }
}

/// Previous, play or pause, and next. Space and ⌘← ⌘→ do the same from the menu bar.
private struct BarTransport: View {
    /// Left off where there's only room for play and next.
    var showsPrevious = true
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousPresses = 0
    @State private var nextPresses = 0

    var body: some View {
        HStack(spacing: 4) {
            if showsPrevious {
                Button {
                    previousPresses += 1
                    player.skipToPrevious()
                } label: {
                    SkipArrows(direction: .backward, height: 12, trigger: previousPresses)
                }
                .buttonStyle(BarIconButtonStyle(diameter: 32))
                .disabled(player.context?.isStation == true)
                .help("Previous (⌘←)")
                .accessibilityLabel("Previous")
            }

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .replace.downUp)))
                    .frame(width: 22)
            }
            .buttonStyle(BarIconButtonStyle(diameter: 38))
            .overlay {
                if player.isPlaying, player.status == .loading || Self.showsLoading {
                    TurningRing(diameter: 36, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                nextPresses += 1
                player.skipToNext()
            } label: {
                SkipArrows(direction: .forward, height: 12, trigger: nextPresses)
            }
            .buttonStyle(BarIconButtonStyle(diameter: 32))
            .help("Next (⌘→)")
            .accessibilityLabel("Next")
        }
    }

    #if DEBUG
    /// `-TracksDemoLoading YES` keeps the ring turning, since sample songs never buffer: for
    /// measuring what it costs.
    private static let showsLoading = UserDefaults.standard.bool(forKey: "TracksDemoLoading")
    #else
    private static let showsLoading = false
    #endif
}

/// The song's progress: the time gone, a thin track that thickens under the pointer and can
/// be clicked or dragged to any point, and the time left.
struct BarScrubber: View {
    let duration: TimeInterval
    var showsTimes = true
    @Environment(PlayerModel.self) private var player
    @Environment(\.isOnScreen) private var isOnScreen
    @State private var dragFraction: Double?
    @State private var isHovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !player.isPlaying || dragFraction != nil || !isOnScreen)) { _ in
            let fraction = dragFraction ?? min(1, max(0, player.playbackTime / duration))
            HStack(spacing: 8) {
                if showsTimes {
                    time(fraction * duration)
                }
                GeometryReader { proxy in
                    let isActive = isHovering || dragFraction != nil
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .offset(x: -proxy.size.width * (1 - fraction))
                    }
                    .frame(height: isActive ? 6 : 4)
                    .clipShape(.capsule)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .onHover { isHovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                dragFraction = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            }
                            .onEnded { _ in
                                if let dragFraction { player.seek(to: dragFraction * duration) }
                                dragFraction = nil
                            }
                    )
                    .animation(.easeOut(duration: 0.13), value: isActive)
                }
                .frame(height: 20)
                if showsTimes {
                    time(max(0, duration - fraction * duration), isRemaining: true)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(Text("\(Scrubber.format(fraction * duration)) of \(Scrubber.format(duration))"))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 15 : -15
                player.seek(to: min(duration, max(0, fraction * duration + step)))
            }
        }
    }

    private func time(_ seconds: TimeInterval, isRemaining: Bool = false) -> some View {
        // Sized by the song's longest time with the ticking one drawn over it, as the bar's.
        Text(verbatim: (isRemaining ? "-" : "") + Scrubber.format(duration))
            .hidden()
            .overlay(alignment: isRemaining ? .leading : .trailing) {
                Text(verbatim: (isRemaining ? "-" : "") + Scrubber.format(seconds))
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // Wide enough for "-10:00", so the track doesn't twitch as the minutes change.
            .frame(minWidth: 38, alignment: isRemaining ? .leading : .trailing)
    }
}

/// Shuffle, its glyph lit in the accent while on, as Music's is.
private struct ShuffleButton: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Button("Shuffle", systemImage: "shuffle") { player.toggleShuffle() }
            .labelStyle(.iconOnly)
            .buttonStyle(BarIconButtonStyle(diameter: 30, isOn: player.isShuffled))
            .help(player.isShuffled ? "Turn Off Shuffle" : "Shuffle")
            .accessibilityValue(player.isShuffled ? Text("On") : Text("Off"))
    }
}

/// Repeat, lit while on, with the one on it for one song.
private struct RepeatButton: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Button("Repeat", systemImage: player.repeatMode == .one ? "repeat.1" : "repeat") { player.cycleRepeat() }
            .labelStyle(.iconOnly)
            .buttonStyle(BarIconButtonStyle(diameter: 30, isOn: player.repeatMode != .off))
            .help(repeatHelp)
            .accessibilityValue(repeatHelp)
    }

    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: String(localized: "Repeat")
        case .all: String(localized: "Repeating All")
        case .one: String(localized: "Repeating One Song")
        }
    }
}

/// While a sleep timer runs: the moon and the time left, to change or turn it off.
private struct BarSleepTimer: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.isOnScreen) private var isOnScreen

    var body: some View {
        // The menu's label never changes while the timer runs: it holds the room for the
        // longest time, and the ticking time is drawn over it. A menu whose label changes is
        // rebuilt by AppKit every second.
        Menu {
            SleepTimerItems(player: player)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                time(longest).hidden()
            }
        }
        .menuStyle(.button)
        .buttonStyle(SleepTimerButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(alignment: .trailing) {
            TimelineView(.animation(minimumInterval: 1, paused: !isOnScreen || player.sleepTimer == .endOfSong)) { context in
                time(longest)
                    .hidden()
                    .overlay(alignment: .leading) { time(label(at: context.date)) }
            }
            .padding(.trailing, SleepTimerButtonStyle.padding)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .help("Sleep Timer")
        .accessibilityLabel("Sleep Timer")
    }

    private func time(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
    }

    /// The widest the time gets: its digits as zeros, from the hour or minutes it started at.
    private var longest: String {
        label(at: .now).replacing(/\d/, with: "0")
    }

    private func label(at date: Date) -> String {
        if player.sleepTimer == .endOfSong { return String(localized: "End of Song") }
        return player.sleepRemaining(at: date).map(Scrubber.format) ?? ""
    }
}

/// The sleep timer's pill in the bar: a soft capsule under the pointer, as the bar's round
/// buttons have.
private struct SleepTimerButtonStyle: ButtonStyle {
    static let padding: CGFloat = 8
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, Self.padding)
            .frame(height: 26)
            .background {
                Capsule()
                    .fill(.primary.opacity(configuration.isPressed ? 0.16 : isHovering ? 0.1 : 0.06))
            }
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.13), value: isHovering)
    }
}

/// One of the panel's pages, from the bar: opens the panel on it, or closes the panel when
/// it's already showing it, as Music's Lyrics and Up Next buttons do.
private struct PanelToggle: View {
    let page: PlayerPanelPage
    let systemImage: String
    let title: LocalizedStringKey
    let shortcut: String
    @Binding var showsPanel: Bool
    @Binding var current: PlayerPanelPage

    private var isOn: Bool { showsPanel && current == page }

    var body: some View {
        Button {
            if isOn {
                showsPanel = false
            } else {
                current = page
                showsPanel = true
            }
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(BarIconButtonStyle(diameter: 30, isOn: isOn, onStyle: .backed))
        .help(Text("\(Text(title)) (\(shortcut))"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A round icon button for the bar: nothing behind it at rest, a soft circle under the
/// pointer. On, as Music shows it: shuffle and repeat light their glyph in the accent; a
/// panel's button, whose panel is open, keeps a soft grey circle behind it.
struct BarIconButtonStyle: ButtonStyle {
    enum OnStyle { case lit, backed }

    var diameter: CGFloat = 30
    var isOn = false
    var onStyle = OnStyle.lit
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let isLit = isOn && onStyle == .lit
        let isBacked = isOn && onStyle == .backed
        return configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isLit ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .opacity(isEnabled ? 1 : 0.35)
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(.primary.opacity(configuration.isPressed ? 0.16 : isBacked ? 0.12 : isHovering && isEnabled ? 0.07 : 0))
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.13), value: isHovering)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

/// AirPlay: the system's own picker, so every speaker the Mac knows is there.
struct RoutePickerButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

/// Opens Stage, the song full screen with a visualizer, for a second display or a TV.
private struct StageBarButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: StageWindow.id)
        } label: {
            Label("Stage", systemImage: "tv")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(BarIconButtonStyle(diameter: 30, isOn: false, onStyle: .backed))
        .help("Stage (⌥⌘P)")
    }
}

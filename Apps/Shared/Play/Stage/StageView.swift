import SwiftUI
import TracksCore
#if os(macOS)
import AppKit
#endif

/// Stage: the song on a screen of its own, for a desk, a TV or a party. The cover, the song's
/// name and a visualizer over one of Now Playing's backgrounds, laid out one of four ways, and
/// nothing else until you want it: a tap, or a click on the Mac, brings up the controls, and
/// another puts them away. They stay until then, so they never go while you reach for them.
struct StageView: View {
    let onClose: () -> Void
    @Environment(PlayerModel.self) private var player
    @AppStorage(StageLayout.storageKey) private var layout = StageLayout.cover
    @AppStorage(StageVisualizer.storageKey) private var visualizer = StageVisualizer.bars
    @AppStorage(StageOption.background) private var background = StageBackground.living
    @AppStorage(StageOption.showsAlbum) private var showsAlbum = true
    @AppStorage(StageOption.showsProgress) private var showsProgress = true
    @AppStorage(StageOption.showsNext) private var showsNext = true
    @AppStorage(StageOption.showsClock) private var showsClock = false
    @AppStorage(StageOption.keepsScreenOn) private var keepsScreenOn = true
    @AppStorage(StageOrientation.storageKey) private var orientation = StageOrientation.landscape
    @AppStorage(StageOption.hintsShown) private var hintsShown = 0
    @State private var showsHint = false
    @State private var tint: Color?
    @State private var levels = SmoothedLevels()
    @State private var palette: [Color] = []
    @State private var showsControls = LaunchScene.opensStageControls
    @State private var customizing = LaunchScene.opensStageCustomizer
    /// Counts what's done on Stage: the controls put themselves away a while after the last.
    @State private var activity = 0
    #if os(macOS)
    @State private var isOverControls = false
    @State private var pointer = PointerMoves()
    #endif
    @FocusState private var isFocused: Bool
    @Environment(\.isOnScreen) private var isOnScreen
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// VoiceOver can't find controls that only a tap brings up, so they stay while it runs.
    private var controlsShown: Bool { showsControls || voiceOver }

    var body: some View {
        ZStack {
            Group {
                if let track = player.current {
                    GeometryReader { proxy in
                        // Each song blurs into the next.
                        // Made afresh when the screen turns as well: MusicKit's covers for
                        // library songs drop their picture when moved to a new place in the
                        // layout, and don't load it again.
                        stage(track, in: proxy.size)
                            .id(StageIdentity(track: track.id, isWide: proxy.size.width > proxy.size.height))
                            .transition(.blurReplace)
                    }
                    .padding(.horizontal, 40)
                    .padding(.vertical, 28)
                    .modifier(PixelShift(isOn: keepsScreenOn))
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "music.note", description: Text("Play something, and it shows here."))
                }
            }
            .foregroundStyle(.white)
            controls
                .opacity(controlsShown ? 1 : 0)
                .allowsHitTesting(controlsShown)
                // Put away, the scrubber stops ticking.
                .environment(\.isOnScreen, isOnScreen && controlsShown)
            if showsHint {
                hint.transition(.opacity)
            }
        }
        // Lit from wherever the layout puts the cover, for the backgrounds lit from behind it.
        .backgroundPreferenceValue(BackdropFocusKey.self) { anchor in
            GeometryReader { proxy in
                StageBackdrop(
                    style: background,
                    cover: player.current?.cover,
                    tint: tint,
                    palette: palette,
                    levels: levels,
                    energy: songEnergy(player.current),
                    isPlaying: player.isPlaying,
                    focus: anchor.map { proxy[$0] }
                )
                .overlay(Color.black.opacity(player.isPlaying ? 0 : 0.3))
                .animation(.easeInOut(duration: 0.8), value: player.isPlaying)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .coverTint(of: player.current?.cover, into: $tint)
        .task(id: player.current?.cover) {
            guard let cover = player.current?.cover else { return }
            let found = await CoverTint.palette(for: cover)
            if !Task.isCancelled { palette = found }
        }
        .animation(.easeInOut(duration: 0.3), value: controlsShown)
        .animation(stageAnimation, value: layout)
        .animation(stageAnimation, value: player.current?.id)
        .contentShape(.rect)
        .onTapGesture(perform: toggleControls)
        #if os(macOS)
        // As in the TV app: moving the pointer brings the controls up, and leaving the
        // window puts them away at once.
        .onContinuousHover { phase in
            switch phase {
            case .active: pointerMoved()
            case .ended: pointerLeft()
            }
        }
        // The window's buttons come and go with the controls.
        .preference(key: StageControlsShownKey.self, value: controlsShown)
        #endif
        .task(id: IdleKey(activity: activity, isShown: showsControls, customizing: customizing)) {
            await putControlsAwayWhenIdle()
        }
        .accessibilityActions {
            // For Switch Control and Voice Control. Under VoiceOver the controls never go.
            if !voiceOver {
                Button(showsControls ? "Hide Controls" : "Show Controls", action: toggleControls)
            }
        }
        .accessibilityAction(.escape, onClose)
        #if os(iOS)
        .toolbarVisibility(controlsShown ? .automatic : .hidden, for: .statusBar)
        .persistentSystemOverlays(.hidden)
        .onChange(of: keepsScreenOn, initial: true) { _, isOn in
            UIApplication.shared.isIdleTimerDisabled = isOn
        }
        .onChange(of: orientation) { StagePresenter.shared.updateOrientation() }
        .onAppear { StagePresenter.shared.updateOrientation() }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            StagePresenter.shared.updateOrientation()
        }
        .sheet(isPresented: $customizing) {
            StageCustomizer()
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        #else
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.space) { player.togglePlayPause(); return .handled }
        .onKeyPress(.rightArrow) { player.skipToNext(); return .handled }
        .onKeyPress(.leftArrow) { player.skipToPrevious(); return .handled }
        .onExitCommand(perform: onClose)
        #endif
        .onAppear {
            if !controlsShown { showHintIfNew() }
        }
        .listensToAudio()
    }

    /// Under Reduce Motion, a new layout or song settles in a moment rather than gliding there.
    private var stageAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.5)
    }

    // MARK: - The four layouts

    @ViewBuilder
    private func stage(_ track: PlayerTrack, in size: CGSize) -> some View {
        switch layout {
        case .cover: coverLayout(track, in: size)
        case .poster: posterLayout(track, in: size)
        case .visualizer: visualizerLayout(track, in: size)
        case .clock: clockLayout(track, in: size)
        }
    }

    /// The cover beside the song's name when there's width for it, above it when there isn't.
    private func coverLayout(_ track: PlayerTrack, in size: CGSize) -> some View {
        let wide = size.width > size.height * 1.1
        let side = wide ? min(size.height * 0.6, size.width * 0.4) : min(size.width * 0.82, size.height * 0.46)
        let layout = wide ? AnyLayout(HStackLayout(spacing: side * 0.14)) : AnyLayout(VStackLayout(spacing: 28))
        return VStack(spacing: 0) {
            topCorner
            Spacer(minLength: 0)
            layout {
                ZStack {
                    if visualizer.surroundsCover {
                        let reach = side * (visualizer == .glow ? 2.1 : 2)
                        visualizerView(track, cover: side).frame(width: reach, height: reach)
                    }
                    CoverImage(cover: track.cover, size: side)
                        .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                        .backdropFocus()
                }
                .frame(width: side, height: side)
                details(track, alignment: wide ? .leading : .center, size: min(size.width * (wide ? 0.045 : 0.09), 64), eyebrow: player.context?.title)
                    .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
            }
            Spacer(minLength: 0)
            if visualizer.isStrip {
                visualizerView(track).frame(height: max(size.height * 0.2, 72))
                    .padding(.bottom, 20)
            }
            footer(track)
        }
    }

    /// The song's name set huge, bottom left, over the background: a gig poster.
    private func posterLayout(_ track: PlayerTrack, in size: CGSize) -> some View {
        let wide = size.width > size.height
        let type = min(size.width * (wide ? 0.11 : 0.15), size.height * (wide ? 0.2 : 0.15))
        return VStack(alignment: .leading, spacing: 0) {
            // Upright, the cover sits at the top; on its side there's no height to spare, so
            // it goes beside the name instead.
            HStack(alignment: .top) {
                if !wide {
                    CoverImage(cover: track.cover, size: min(96, size.width * 0.18))
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                }
                Spacer()
                if showsClock { clock(size: 28) }
            }
            Spacer(minLength: 0)
            // No cover large enough here for the halo to light, so the waveform.
            if visualizer != .off {
                visualizerView(track, style: visualizer == .halo ? .waveform : visualizer)
                    .frame(height: size.height * (visualizer == .glow ? 0.34 : wide ? 0.2 : 0.26))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
            }
            HStack(spacing: 12) {
                if wide {
                    CoverImage(cover: track.cover, size: max(28, type * 0.5))
                }
                Text(track.artistName.uppercased())
                    .font(.system(size: max(15, type * 0.28), weight: .semibold))
                    .tracking(2)
                    .opacity(0.85)
                    .lineLimit(1)
            }
            Text(track.title)
                .font(.system(size: type, weight: .heavy))
                .tracking(-type * 0.02)
                .lineLimit(3)
                .minimumScaleFactor(0.4)
                .padding(.top, 2)
            if showsAlbum, let album = track.albumTitle {
                Text(album)
                    .font(.system(size: max(15, type * 0.26), weight: .medium))
                    .opacity(0.7)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
            footer(track)
                .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The visualizer at the centre: the glow or the halo around the cover, or the waveform
    /// large, with the song under it.
    private func visualizerLayout(_ track: PlayerTrack, in size: CGSize) -> some View {
        let side = min(size.width, size.height * 0.62)
        let cover = side * 0.62
        return VStack(spacing: 0) {
            topCorner
            Spacer(minLength: 0)
            switch visualizer {
            case .glow, .halo:
                ZStack {
                    if visualizer == .glow {
                        // A wide cloud, as the screen is.
                        visualizerView(track, cover: cover).frame(width: min(size.width, side * 2.6), height: side * 1.7)
                    } else {
                        visualizerView(track, cover: cover).frame(width: cover * 2.4, height: cover * 2.4)
                    }
                    CoverImage(cover: track.cover, size: cover)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                        .backdropFocus()
                }
                .frame(width: side, height: side)
            case .bars, .waveform:
                visualizerView(track).frame(height: size.height * 0.42)
            case .off:
                CoverImage(cover: track.cover, size: side * 0.8)
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 16)
                    .backdropFocus()
            }
            Spacer(minLength: 0)
            details(track, alignment: .center, size: min(size.width * (size.width > size.height ? 0.05 : 0.085), 48))
            footer(track)
                .padding(.top, 24)
        }
    }

    /// The time, as StandBy shows it, with the song and a small visualizer under it.
    private func clockLayout(_ track: PlayerTrack, in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 0) {
                    // As StandBy shows it: the hours and minutes alone, in the cover's light.
                    Text(context.date, format: Self.time)
                        .font(.system(size: min(size.width * 0.24, size.height * 0.36), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(clockColor)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        // Halo lights the time, the cover here being small.
                        .backdropFocus()
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.title2.weight(.semibold))
                        .opacity(0.7)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 16) {
                CoverImage(cover: track.cover, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(track.artistName).font(.body).opacity(0.7).lineLimit(1)
                }
                Spacer(minLength: 12)
                if visualizer != .off {
                    // Too small for light around the cover; bars and the waveform read at any size.
                    visualizerView(track, style: visualizer == .bars ? .bars : .waveform)
                        .frame(width: min(220, size.width * 0.3), height: 48)
                }
            }
            footer(track)
                .padding(.top, 20)
        }
    }

    // MARK: - Pieces

    private func details(_ track: PlayerTrack, alignment: HorizontalAlignment, size: CGFloat, eyebrow: String? = nil) -> some View {
        let textAlignment: TextAlignment = alignment == .center ? .center : .leading
        return VStack(alignment: alignment, spacing: size * 0.14) {
            // Where it's playing from, as Now Playing says it.
            if let eyebrow {
                Text(eyebrow.uppercased())
                    .font(.system(size: max(12, size * 0.3), weight: .semibold))
                    .tracking(1.5)
                    .opacity(0.6)
                    .lineLimit(1)
            }
            Text(track.title)
                .font(.system(size: size, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(track.artistName)
                .font(.system(size: size * 0.6, weight: .medium))
                .opacity(0.8)
                .lineLimit(1)
            if showsAlbum, let album = track.albumTitle {
                Text(album)
                    .font(.system(size: size * 0.45))
                    .opacity(0.6)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(textAlignment)
    }

    /// The clock in the top corner, for the layouts that aren't one.
    @ViewBuilder
    private var topCorner: some View {
        if showsClock {
            HStack {
                Spacer()
                clock(size: 24)
            }
        }
    }

    private func clock(size: CGFloat) -> some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, format: Self.time)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(clockColor)
        }
    }

    private static let time = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()

    /// The cover's lightest colour, well lifted toward white, as StandBy tints its clock.
    private var clockColor: Color {
        (palette.last ?? .white).mix(with: .white, by: 0.6)
    }

    /// How far into the song, and what's next, along the bottom.
    @ViewBuilder
    private func footer(_ track: PlayerTrack) -> some View {
        let next = showsNext ? player.upNext.first : nil
        if showsProgress || next != nil || !player.isPlaying {
            VStack(alignment: .leading, spacing: 10) {
                if showsProgress, let duration = track.duration, duration > 0, duration.isFinite {
                    TimelineView(.animation(minimumInterval: 1, paused: !player.isPlaying || !isOnScreen)) { _ in
                        let fraction = Scrubber.fraction(player.playbackTime, of: duration)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.2))
                                // Slid along rather than resized, so each tick only redraws.
                                Capsule()
                                    .fill(.white.opacity(0.75))
                                    .offset(x: -proxy.size.width * (1 - fraction))
                            }
                            .clipShape(.capsule)
                        }
                        .frame(height: 4)
                    }
                }
                HStack(spacing: 10) {
                    if !player.isPlaying {
                        Label("Paused", systemImage: "pause.fill")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.18), in: .capsule)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    if let next {
                        Text("Next: \(next.title) · \(next.artistName)")
                            .font(.callout.weight(.medium))
                            .opacity(0.7)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                .animation(.smooth(duration: 0.3), value: player.isPlaying)
            }
        }
    }

    /// `cover` is the side of the cover the visualizer surrounds, centred in it.
    private func visualizerView(_ track: PlayerTrack, style: StageVisualizer? = nil, cover: CGFloat = 0) -> some View {
        StageVisualizerView(style: style ?? visualizer, palette: palette, energy: songEnergy(track), isPlaying: player.isPlaying, levels: levels, cover: cover)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                controlButton("Close Stage", symbol: "xmark", action: onClose)
                Spacer()
                #if os(iOS)
                controlButton(orientation == .portrait ? "Turn to Landscape" : "Turn to Portrait", symbol: "rectangle.portrait.rotate") {
                    orientation = orientation == .portrait ? .landscape : .portrait
                }
                RoutePicker()
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                #endif
                controlButton("Customize", symbol: "slider.horizontal.3") { customizing.toggle() }
                    #if os(macOS)
                    .popover(isPresented: $customizing, arrowEdge: .bottom) {
                        StageCustomizer().frame(width: 360, height: 520)
                    }
                    #endif
            }
            #if os(macOS)
            .onHover { isOverControls = $0 }
            #endif
            Spacer()
            if let track = player.current {
                VStack(spacing: isShort ? 8 : 18) {
                    if let duration = track.duration, duration > 0, duration.isFinite {
                        Scrubber(duration: duration, isPlaying: player.isPlaying, time: { player.playbackTime }, track: track, interval: Scrubber.platformInterval) { time in
                            player.seek(to: time)
                        }
                    } else {
                        LiveScrubber()
                    }
                    PlayerTransport()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, isShort ? 12 : 22)
                .frame(maxWidth: 560)
                .glassEffect(.regular, in: .rect(cornerRadius: 34))
                // A tap that just misses a button stays on the panel, rather than putting
                // the controls away from under the finger.
                .contentShape(.rect(cornerRadius: 34))
                .onTapGesture {}
                #if os(macOS)
                .onHover { isOverControls = $0 }
                #endif
            }
        }
        // Anything done with the controls keeps them up a while longer.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in activity += 1 })
        .foregroundStyle(.white)
        .padding(24)
        #if os(macOS)
        // Below the window's own buttons, which come up with these, rather than crowding them.
        .padding(.top, 20)
        #endif
        .background {
            // Shade over the song, deeper top and bottom, so the controls sit over it rather
            // than among it.
            LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.2), .black.opacity(0.2), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    /// iPhone on its side: the panel keeps to its controls, with little room to spare.
    private var isShort: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    private func controlButton(_ label: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    /// A word about the controls the first few times Stage opens, since at first it shows none.
    private var hint: some View {
        Group {
            #if os(iOS)
            Text("Tap to show controls")
            #else
            Text("Move the pointer to show controls")
            #endif
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Around the words alone: around the whole height, it was a pillar of glass.
        .glassEffect(.regular, in: .capsule)
        // At the top, where the system says how to leave full screen, and clear of the
        // progress and what's next along the foot.
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func showHintIfNew() {
        guard hintsShown < 3 else { return }
        hintsShown += 1
        showsHint = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.easeOut(duration: 0.6)) { showsHint = false }
        }
    }

    /// A tap or click anywhere but on a control shows the controls, or puts them away. Not
    /// while Stage is being customized, which keeps them up behind it.
    private func toggleControls() {
        guard !customizing else { return }
        showsHint = false
        showsControls.toggle()
        activity += 1
        #if os(macOS)
        // Put away, they take the pointer with them until it's moved.
        if !showsControls { NSCursor.setHiddenUntilMouseMoves(true) }
        #endif
    }

    /// What the idle timer restarts on.
    private struct IdleKey: Hashable {
        let activity: Int
        let isShown: Bool
        let customizing: Bool
    }

    /// Puts the controls away once nothing's been done with them for a few seconds, as a video
    /// player does, so a Stage left on doesn't keep them over the song. Not while customizing,
    /// under VoiceOver, or with the pointer resting on them.
    private func putControlsAwayWhenIdle() async {
        guard showsControls, !customizing, !LaunchScene.opensStageControls else { return }
        #if os(macOS)
        let wait = 3.0
        #else
        let wait = 5.0
        #endif
        try? await Task.sleep(for: .seconds(wait))
        guard !Task.isCancelled, !voiceOver, !customizing else { return }
        #if os(macOS)
        guard !isOverControls else { return }
        NSCursor.setHiddenUntilMouseMoves(true)
        #endif
        showsControls = false
    }

    #if os(macOS)
    private func pointerMoved() {
        // Each move restarts the wait, but not more than twice a second.
        guard !showsControls || pointer.isDue else { return }
        showsHint = false
        showsControls = true
        activity += 1
    }

    private func pointerLeft() {
        guard showsControls, !customizing, !voiceOver, !LaunchScene.opensStageControls else { return }
        showsHint = false
        showsControls = false
    }
    #endif
}

#if os(macOS)
/// Whether Stage's controls are up, for its window to show its buttons with them.
struct StageControlsShownKey: PreferenceKey {
    static let defaultValue = true

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

/// When the pointer last restarted Stage's idle wait. Not observed: a move redraws nothing.
private final class PointerMoves {
    private var last = Date.distantPast

    var isDue: Bool {
        guard Date.now.timeIntervalSince(last) > 0.5 else { return false }
        last = .now
        return true
    }
}
#endif

/// Moves what's on Stage a few points over the minutes, too slowly to see, so a screen kept on
/// for hours doesn't keep the same picture burned in one place.
/// What Stage's layout is made afresh for: a new song, or the screen turning.
private struct StageIdentity: Hashable {
    let track: String
    let isWide: Bool
}

private struct PixelShift: ViewModifier {
    let isOn: Bool
    @Environment(\.isOnScreen) private var isOnScreen

    func body(content: Content) -> some View {
        // Once a minute, a step of a point or two: nothing to animate, and nothing drawn between.
        TimelineView(.animation(minimumInterval: 60, paused: !isOn || !isOnScreen)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            content
                .offset(x: isOn ? 8 * sin(time / 311) : 0, y: isOn ? 6 * cos(time / 409) : 0)
        }
    }
}

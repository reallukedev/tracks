import SwiftUI
import TracksCore

/// Music's full-screen player, over the whole window: the cover large on a field of its own
/// colour, the song and your count beside it, and the transport under them. Click the cover,
/// or Your History, and the sleeve turns over to your history with the song. Escape, or the
/// chevron, goes back to the window.
struct FullPlayer: View {
    /// Whether the sleeve is turned over and Up Next is out: the window's, so the Controls
    /// menu's Show Up Next and Show Your History reach them.
    let window: PlayerWindowState
    let close: () -> Void
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openPlayRoute) private var openPlayRoute
    @Environment(\.openRadioTuner) private var openRadioTuner
    @State private var tint: Color?

    private var showsBack: Bool {
        get { window.fullPlayerShowsHistory }
        nonmutating set { window.fullPlayerShowsHistory = newValue }
    }

    private var showsUpNext: Bool {
        get { window.fullPlayerShowsUpNext }
        nonmutating set { window.fullPlayerShowsUpNext = newValue }
    }

    var body: some View {
        ZStack {
            Color.clear
            if let track = player.current {
                content(track)
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(.white)
                    // What's on lights white on the cover's colour, as on the iPhone's.
                    .tint(.white)
            }
        }
        // Lit from the cover, wherever the window's size puts it.
        .nowPlayingBackdrop(cover: player.current?.cover, tint: tint, isPlaying: player.isPlaying)
        .coverTint(of: player.current?.cover, into: $tint)
        .onChange(of: player.current?.songIdentity) { showsBack = false }
        .onExitCommand(perform: close)
    }

    private func content(_ track: PlayerTrack) -> some View {
        VStack(spacing: 0) {
            topBar(track)
            GeometryReader { proxy in
                // The cover as big as the window allows, leaving the column beside it its
                // width and the top bar its height.
                let side = max(220, min(480, proxy.size.height - 40, proxy.size.width - Self.column - Self.gap - 96))
                HStack(alignment: .center, spacing: Self.gap) {
                    sleeve(track, side: side)
                    Group {
                        if showsUpNext {
                            upNext
                        } else {
                            details(track)
                        }
                    }
                    .frame(width: Self.column)
                    // The column stands as tall as the cover: the song's name level with its
                    // top edge, the controls with its bottom. Never shorter than the details need,
                    // which a small window's cover can be.
                    .frame(height: max(side, Self.columnHeight))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 32)
        }
        .padding(.bottom, 32)
        // Up into the title bar, whose buttons hide while the full player is open, so its
        // own bar sits where they were rather than a bar's height below.
        .ignoresSafeArea(edges: .top)
    }

    private static let column: CGFloat = 380
    /// The song's details and every control, stacked with their least spacing.
    private static let columnHeight: CGFloat = 330
    private static let gap: CGFloat = 56
    private static let barInset: CGFloat = 18

    // MARK: - Top bar

    private func topBar(_ track: PlayerTrack) -> some View {
        ZStack {
            if let context = player.context {
                VStack(spacing: 1) {
                    Text(context.isStation ? "Playing from Radio" : "Playing From")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    Text(player.isRadioDriving ? "\(Image(systemName: "car.fill")) \(context.title) · Driving" : "\(context.title)")
                        .font(.headline)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Button("Exit Full Player", systemImage: "chevron.down", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(BarIconButtonStyle(diameter: 34))
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Exit Full Player (Esc)")
                Spacer()
                Menu("More", systemImage: "ellipsis") {
                    NowPlayingMenuItems(track: track, onNavigate: { destination in
                        close()
                        switch destination {
                        case .play(let route): openPlayRoute(route)
                        case .stats(let route): openPlayRoute(.stats(route))
                        }
                    }, onTuneRadio: openRadioTuner.map { open in { open() } }, showsFavorite: false)
                    Divider()
                    SleepTimerMenu()
                }
                .labelStyle(.iconOnly)
                .menuStyle(.button)
                .buttonStyle(BarIconButtonStyle(diameter: 34))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
        // Its buttons as far in from the window's top as from its sides, clear of the
        // rounded corners, with the title centred on them.
        .padding(.horizontal, Self.barInset)
        .padding(.top, Self.barInset)
        .padding(.bottom, 12)
    }

    // MARK: - The sleeve

    private func sleeve(_ track: PlayerTrack, side: CGFloat) -> some View {
        // Music's gesture: the cover sinks back while paused.
        let sinks = !player.isPlaying && !reduceMotion && !showsBack
        return SleeveFlip(showsBack: showsBack) {
            Button {
                showsBack = true
            } label: {
                CoverImage(cover: track.cover, size: side)
            }
            .buttonStyle(.plain)
            .help("Your History with This Song")
            .accessibilityLabel("Your History with This Song")
        } back: {
            LinerNotes(track: track, fillsCard: true) {
                close()
                openPlayRoute(.stats(.song(track.songIdentity)))
            }
            .padding(32)
            .frame(width: side, height: side, alignment: .topLeading)
            .background(.white.opacity(0.1), in: .rect(cornerRadius: CoverImage.radius(for: side), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CoverImage.radius(for: side), style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            // A click anywhere on the back but its button turns it face up again.
            .contentShape(.rect(cornerRadius: CoverImage.radius(for: side), style: .continuous))
            .onTapGesture { showsBack = false }
            .help("Show the Cover")
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Show the Cover") { showsBack = false }
        }
        .backdropFocus()
        .shadow(color: .black.opacity(sinks ? 0.2 : 0.4), radius: sinks ? 14 : 30, y: sinks ? 6 : 16)
        .scaleEffect(sinks ? 0.88 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.2), value: sinks)
    }

    // MARK: - Details

    private func details(_ track: PlayerTrack) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                // A click on the name or the artist offers the album and the artist.
                NowPlayingTitleMenu(track: track, onNavigate: { destination in
                    close()
                    switch destination {
                    case .play(let route): openPlayRoute(route)
                    case .stats(let route): openPlayRoute(.stats(route))
                    }
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(track.title)
                                .font(.system(size: 28, weight: .bold))
                                .lineLimit(2)
                            if track.isExplicit {
                                ExplicitBadge()
                            }
                        }
                        Text(track.artistName)
                            .font(.title2)
                            // Strong enough to read on the brightest moving backgrounds.
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    .multilineTextAlignment(.leading)
                }
                .help("Go to Album or Artist")
                PlayCountLine(track: track)
                    .font(.title3)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 24)

            if let duration = track.duration, duration > 0 {
                Scrubber(duration: duration, isPlaying: player.isPlaying, time: { player.playbackTime }, track: track, interval: Scrubber.platformInterval) { time in
                    player.seek(to: time)
                }
            } else {
                LiveScrubber()
            }

            FullPlayerTransport()
                .padding(.top, 16)

            secondaryControls
                .padding(.top, 24)
        }
    }

    private var secondaryControls: some View {
        HStack(spacing: 6) {
            if player.context?.isStation != true, !player.isLive {
                Button("Shuffle", systemImage: "shuffle") { player.toggleShuffle() }
                    .buttonStyle(BarIconButtonStyle(diameter: 36, isOn: player.isShuffled))
                    .help(player.isShuffled ? "Turn Off Shuffle" : "Shuffle")
                    .accessibilityValue(player.isShuffled ? Text("On") : Text("Off"))
                Button("Repeat", systemImage: player.repeatMode == .one ? "repeat.1" : "repeat") { player.cycleRepeat() }
                    .buttonStyle(BarIconButtonStyle(diameter: 36, isOn: player.repeatMode != .off))
                    .help(repeatHelp)
                    .accessibilityValue(repeatHelp)
            }
            if let track = player.current {
                FavoriteStarButton(track: track) { systemImage, _ in
                    Label("Favorite", systemImage: systemImage)
                }
                .menuStyle(.button)
                .buttonStyle(BarIconButtonStyle(diameter: 36))
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Spacer()
            Button("Your History", systemImage: "clock.arrow.circlepath") { showsBack.toggle() }
                .buttonStyle(BarIconButtonStyle(diameter: 36, isOn: showsBack))
                .help("Your History (⌥⌘Y)")
            RoutePickerButton()
                .frame(width: 36, height: 36)
                .help("AirPlay")
            Button("Up Next", systemImage: "list.bullet") {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showsUpNext.toggle() }
            }
            .buttonStyle(BarIconButtonStyle(diameter: 36, isOn: showsUpNext))
            .help("Up Next (⌥⌘U)")
        }
        .labelStyle(.iconOnly)
    }

    private var repeatHelp: String {
        switch player.repeatMode {
        case .off: String(localized: "Repeat")
        case .all: String(localized: "Repeating All")
        case .one: String(localized: "Repeating One Song")
        }
    }

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Up Next")
                    .font(.title2.bold())
                Spacer()
                Button("Done") {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showsUpNext = false }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
            UpNextList()
                // Go to Album and the like leave the full player for the page they open.
                .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "fullPlayer") { route in
                    close()
                    openPlayRoute(route)
                })
        }
    }
}

/// Previous, play or pause, and next, at the Mac's size: a soft circle under the pointer, a
/// little give under a click, and what each does in its help, with its shortcut.
private struct FullPlayerTransport: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousPresses = 0
    @State private var nextPresses = 0

    var body: some View {
        HStack(spacing: 28) {
            Button {
                previousPresses += 1
                player.skipToPrevious()
            } label: {
                SkipArrows(direction: .backward, height: 17, trigger: previousPresses)
            }
            .buttonStyle(BarIconButtonStyle(diameter: 44))
            .disabled(player.context?.isStation == true)
            .help("Previous (⌘←)")
            .accessibilityLabel("Previous")

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.magic(fallback: .replace.downUp)))
                    .frame(width: 32)
            }
            .buttonStyle(BarIconButtonStyle(diameter: 56))
            .overlay {
                if player.isPlaying, player.status == .loading {
                    TurningRing(diameter: 54, lineWidth: 2, color: .primary.opacity(0.5))
                        .allowsHitTesting(false)
                }
            }
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .accessibilityValue(player.isPlaying && player.status == .loading ? Text("Loading") : Text(""))

            Button {
                nextPresses += 1
                player.skipToNext()
            } label: {
                SkipArrows(direction: .forward, height: 17, trigger: nextPresses)
            }
            .buttonStyle(BarIconButtonStyle(diameter: 44))
            .help("Next (⌘→)")
            .accessibilityLabel("Next")
        }
        .frame(maxWidth: .infinity)
    }
}

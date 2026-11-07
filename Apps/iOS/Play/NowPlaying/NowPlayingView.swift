import SwiftUI
import MusicKit
import TracksCore

/// The full player: one song, huge, on a field of its own colour, with the transport where the
/// thumb is. Music's Now Playing, plus what only Tracks knows: how many times you've heard this,
/// counting up the moment it's kept, and, a double tap on the cover or the history button away,
/// the back of its sleeve with your whole history with it.
struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.isOnScreen) private var isOnScreen
    @State private var showsQueue = LaunchScene.opensQueue
    @State private var showsBack = LaunchScene.opensSleeve
    /// Tracks Radio's tuning, from Up Next or the song's menu. Presented from here, outside the
    /// stage's dark look, so the sheet reads as Settings does.
    @State private var showsTuner = LaunchScene.opensRadioTunerFromQueue
    @State private var showsDevices = false
    /// Turns of the sleeve, for the haptic: only the person turns it.
    @State private var turns = 0
    @State private var tint: Color?
    /// The heights of what stands above and below the cover, which grow with the text.
    @State private var topBarHeight: CGFloat = 0
    @State private var detailsHeight: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0
    /// Where to go once the cover has closed: Go to Album and the like.
    let onNavigate: (NowPlayingDestination) -> Void

    var body: some View {
        ZStack {
            Color.clear
            if let track = player.current {
                content(track)
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(.white)
                    // Music stops growing its player here too: past it, the song's own name
                    // no longer fits beside the cover and the controls.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .environment(\.openRadioTuner, OpenRadioTunerAction { showsTuner = true })
            }
        }
        // Lit from the cover, wherever the layout puts it.
        .nowPlayingBackdrop(cover: player.current?.cover, tint: tint, isPlaying: player.isPlaying)
        .sheet(isPresented: $showsTuner) { RadioTunerSheet() }
        .sheet(isPresented: $showsDevices) {
            DevicesSheet { showsDevices = false }
        }
        .coverTint(of: player.current?.cover, into: $tint)
        .onChange(of: player.hasQueue) { _, hasQueue in
            if !hasQueue { dismiss() }
        }
        // A new song starts face up.
        .onChange(of: player.current?.songIdentity) { showsBack = false }
        .sensoryFeedback(.selection, trigger: turns)
        .playerFeedback()
        // Under Stage nothing here can be seen, so its background and clocks rest.
        .environment(\.isOnScreen, isOnScreen && !StagePresenter.shared.isShowing)
        .fullScreenCover(isPresented: Bindable(StagePresenter.shared).isShowing) {
            StageView { StagePresenter.shared.isShowing = false }
                .environment(player)
        }
        .onChange(of: player.hasQueue, initial: true) { _, hasQueue in
            if hasQueue, LaunchScene.opensStage { StagePresenter.shared.isShowing = true }
            if hasQueue, LaunchScene.opensSharePlayCode {
                // Once the cover has finished coming up, or the sheet has nothing to show from.
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    SharePlayController.shared.showsCode = true
                }
            }
        }
        // SharePlay's code, from the menu or Up Next.
        .sheet(isPresented: Bindable(SharePlayController.shared).showsCode) { SharePlayCodeSheet() }
    }

    // MARK: - Layout

    private func content(_ track: PlayerTrack) -> some View {
        GeometryReader { proxy in
            // The bottom row sits down by the home indicator, as Music's does, and in the
            // same place whether the cover or Up Next is up: a fixed inset into the safe area
            // rather than wherever the content happened to overflow to.
            let bottomInset = Self.bottomInset(proxy)
            VStack(spacing: 0) {
                topBar
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { topBarHeight = $0 }
                if showsQueue {
                    QueueView(track: track)
                        .transition(.opacity)
                } else {
                    Spacer(minLength: 12)
                    sleeve(track, in: proxy)
                    Spacer(minLength: 20)
                    details(track)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { detailsHeight = $0 }
                }
                Spacer(minLength: 16)
                controls(track)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { controlsHeight = $0 }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, bottomInset)
            .frame(width: proxy.size.width, height: proxy.size.height + proxy.safeAreaInsets.bottom, alignment: .top)
        }
    }

    /// From the screen's foot to the bottom row: 14 points into the safe area, or 8 on a
    /// screen without one.
    private static func bottomInset(_ proxy: GeometryProxy) -> CGFloat {
        max(8, proxy.safeAreaInsets.bottom - 14)
    }

    private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                if player.isOnAutoplayPick {
                    Text("Autoplay")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(player.autoplayFollows.map { "Songs Like \($0)" } ?? "Similar Songs")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                } else if let context = player.context {
                    Text(context.isStation ? "Playing from Radio" : "Playing From")
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(player.isRadioDriving ? "\(Image(systemName: "car.fill")) \(context.title) · Driving" : "\(context.title)")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 56)
            .accessibilityElement(children: .combine)

            HStack {
                Button("Close", systemImage: "chevron.down") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    /// The cover, which turns over to your history with the song.
    private func sleeve(_ track: PlayerTrack, in proxy: GeometryProxy) -> some View {
        let available = proxy.size
        // Laid out once at no size at all as the player opens, then at the screen's. At the
        // larger text sizes the title and controls grow, and the cover gives them the room
        // rather than push the bottom row off the screen: what's left once they and the
        // spaces between them (12, 20 and 16) and the inset below have theirs.
        let share = verticalSizeClass == .compact ? 0.5 : 0.44
        let room = available.height + proxy.safeAreaInsets.bottom - Self.bottomInset(proxy)
            - topBarHeight - detailsHeight - controlsHeight - 48
        let side = max(0, min(available.width - 56, available.height * share, room, 420))
        // Music's gesture: the cover sinks back while paused. Not while its back is up, which
        // is being read.
        let sinks = !player.isPlaying && !reduceMotion && !showsBack
        let shape = RoundedRectangle(cornerRadius: CoverImage.radius(for: side), style: .continuous)
        // A single tap on either side does nothing: the cover is where a thumb lands to swipe
        // Now Playing closed, and a short swipe mustn't read as a tap and turn it instead. A
        // double tap turns it, which no swipe can be; the history button below always does.
        return SleeveFlip(showsBack: showsBack) {
            CoverImage(cover: track.cover, size: side)
                .contentShape(shape)
                .onTapGesture(count: 2, perform: turnSleeve)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Artwork")
                .accessibilityAction(named: "Your History", turnSleeve)
        } back: {
            LinerNotes(track: track, isCompact: true, fillsCard: true) {
                navigate(.stats(.song(track.songIdentity)))
            }
            .padding(22)
            .frame(width: side, height: side, alignment: .topLeading)
            .background(.white.opacity(0.1), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 1) }
            .contentShape(shape)
            .onTapGesture(count: 2, perform: turnSleeve)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Show the Cover", turnSleeve)
        }
        .backdropFocus()
        .shadow(color: .black.opacity(sinks ? 0.2 : 0.4), radius: sinks ? 14 : 30, y: sinks ? 6 : 16)
        .scaleEffect(sinks ? 0.82 : 1)
        .animation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.2), value: sinks)
        .frame(maxWidth: .infinity)
    }

    private func turnSleeve() {
        turns += 1
        showsBack.toggle()
    }

    private func details(_ track: PlayerTrack) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                // A tap on the name or the artist offers the album and the artist, as Music's do.
                NowPlayingTitleMenu(track: track, onNavigate: navigate) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.title2.bold())
                            .lineLimit(2)
                        Text(track.artistName)
                            .font(.title3)
                            // Strong enough to read on the brightest moving backgrounds.
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                PlayCountLine(track: track)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NowPlayingMenu(track: track, onNavigate: navigate)
        }
    }

    private func controls(_ track: PlayerTrack) -> some View {
        VStack(spacing: 22) {
            if let duration = track.duration, duration > 0 {
                Scrubber(duration: duration, isPlaying: player.isPlaying, time: { player.playbackTime }, track: track) { time in
                    player.seek(to: time)
                }
            } else {
                LiveScrubber()
            }

            PlayerTransport()

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
                // A volume view in the window keeps iPhone's own volume display away, even
                // under Stage's cover, where the buttons then seemed to do nothing.
                Group {
                    if StagePresenter.shared.isShowing {
                        Color.clear
                    } else {
                        VolumeSlider()
                    }
                }
                .frame(height: 34)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .accessibilityHidden(true)
            }

            HStack {
                FavoriteStarButton(track: track) { systemImage, isOn in
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(isOn ? 1 : 0.7))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                Spacer()
                pageToggle(isOn: showsBack && !showsQueue, systemImage: "clock.arrow.circlepath", label: showsBack ? "Show the Cover" : "Your History") {
                    if showsQueue {
                        withAnimation(reduceMotion ? nil : PlayMotion.panel) { showsQueue = false }
                        if !showsBack { turnSleeve() }
                    } else {
                        turnSleeve()
                    }
                }
                Spacer()
                RoutePicker()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("AirPlay")
                Spacer()
                NowPlayingDevicesButton { showsDevices = true }
                pageToggle(isOn: showsQueue, systemImage: "list.bullet", label: showsQueue ? "Hide Up Next" : "Up Next") {
                    withAnimation(reduceMotion ? nil : PlayMotion.panel) { showsQueue.toggle() }
                }
            }
        }
    }

    /// One of the bottom row's page buttons: lit in a white circle while its page is up, as
    /// Music's Lyrics and Up Next buttons are. A circle sits with the screen's round corners
    /// and the round More button, where a square looked boxed in.
    private func pageToggle(isOn: Bool, systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isOn ? .black : .white.opacity(0.7))
                .frame(width: 40, height: 40)
                .background(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.clear), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func navigate(_ destination: NowPlayingDestination) {
        dismiss()
        onNavigate(destination)
    }
}

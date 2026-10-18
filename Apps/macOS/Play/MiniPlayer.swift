import SwiftUI
import TracksCore

/// Music's Mini Player: the cover alone in a small window that stays above the others, with
/// the song and its controls over it while the pointer is there.
struct MiniPlayerWindow: Scene {
    static let id = "mini-player"
    /// Whether it's open, for the Window menu's Switch to and from Mini Player.
    static let presence = Presence()
    let model: AppModel

    @MainActor
    @Observable
    final class Presence {
        fileprivate(set) var isOpen = false
    }

    var body: some Scene {
        Window("Mini Player", id: Self.id) {
            if let capture = model.capture {
                MiniPlayer()
                    .opensSongInfo(model)
                    .tracksOnScreen()
                    .environment(model)
                    .environment(model.player)
                    .environment(model.playFeed)
                    .environment(model.yourMusic)
                    .environment(capture)
                    .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "miniPlayer") { route in
                        // Pages open in the main window, brought forward for them, or opened
                        // again if it was closed.
                        model.playNavigator.show(route)
                        if let openWindow = MacAppDelegate.openWindow {
                            MainWindow.bringForward(openWindow: openWindow)
                        } else {
                            NSApp.activate(ignoringOtherApps: true)
                            MainWindow.open?.makeKeyAndOrderFront(nil)
                        }
                    })
            }
        }
        // No title bar at all: the cover is the whole window, dragged anywhere by its cover.
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowLevel(.floating)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.bottomTrailing)
        .restorationBehavior(.disabled)
        // The Window menu has it, as Switch to Mini Player and Mini Player.
        .commandsRemoved()
    }
}

private struct MiniPlayer: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var isHovering = false
    @State private var nextPresses = 0
    @State private var previousPresses = 0
    @State private var tint: Color?

    static let side: CGFloat = 300
    static let cornerRadius: CGFloat = 14
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(YourMusic.self) private var music

    var body: some View {
        ZStack(alignment: .bottom) {
            if let track = player.current {
                CoverImage(cover: track.cover, size: Self.side, isBare: true)
                // Always there, so VoiceOver and the keyboard can reach them; shown while the
                // pointer is over the window, or the music is paused.
                controls(track)
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)
            } else {
                nothingPlaying
            }
        }
        .overlay(alignment: .top) {
            windowButtons
                .opacity(isHovering || voiceOver ? 1 : 0)
                .allowsHitTesting(isHovering || voiceOver)
        }
        .frame(width: Self.side, height: Self.side)
        .background {
            // The cover fills the window, so only its colour shows, round the edges as it loads.
            CoverStage(tint: tint)
        }
        .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .coverTint(of: player.current?.cover, into: $tint)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isHovering = hovering }
        }
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            MiniPlayerWindow.presence.isOpen = true
            MacAppDelegate.openWindow = openWindow
        }
        .onDisappear { MiniPlayerWindow.presence.isOpen = false }
        // Add to Playlist picks in the main window, so it comes forward for the sheet.
        .onChange(of: music.playlists.picking?.id) { _, id in
            if id != nil { MainWindow.bringForward(openWindow: openWindow) }
        }
        .contextMenu {
            if let track = player.current {
                Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause" : "play") { player.togglePlayPause() }
                Button("Next", systemImage: "forward") { player.skipToNext() }
                Button("Previous", systemImage: "backward") { player.skipToPrevious() }
                    .disabled(player.context?.isStation == true)
                Divider()
                NowPlayingMenuItems(track: track)
            }
            Divider()
            Button("Switch from Mini Player", systemImage: "macwindow", action: switchToMainWindow)
            Button("Close Mini Player", systemImage: "xmark") { dismissWindow(id: MiniPlayerWindow.id) }
        }
    }

    /// Music's: the main window back in its place.
    private func switchToMainWindow() {
        dismissWindow(id: MiniPlayerWindow.id)
        MainWindow.bringForward(openWindow: openWindow)
    }

    /// Close at the top left, where a window's is, and the main window at the top right, over
    /// a shade so they read on any cover.
    private var windowButtons: some View {
        HStack {
            Button("Close Mini Player", systemImage: "xmark") { dismissWindow(id: MiniPlayerWindow.id) }
                .help("Close Mini Player")
            Spacer()
            Button("Switch from Mini Player", systemImage: "macwindow", action: switchToMainWindow)
                .help("Switch from Mini Player (⇧⌘M)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(MiniWindowButtonStyle())
        .padding(10)
        .padding(.bottom, 24)
        .background {
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .environment(\.colorScheme, .dark)
    }

    private var showsControls: Bool {
        isHovering || !player.isPlaying || voiceOver
    }

    private func controls(_ track: PlayerTrack) -> some View {
        VStack(spacing: 10) {
            VStack(spacing: 2) {
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                PlayCountLine(track: track, showsSince: false)
                    .font(.caption)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 18) {
                Button {
                    previousPresses += 1
                    player.skipToPrevious()
                } label: {
                    SkipArrows(direction: .backward, height: 14, trigger: previousPresses)
                }
                .buttonStyle(BarIconButtonStyle(diameter: 36))
                .disabled(player.context?.isStation == true)
                .help("Previous (⌘←)")
                .accessibilityLabel("Previous")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                }
                .buttonStyle(BarIconButtonStyle(diameter: 44))
                .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    nextPresses += 1
                    player.skipToNext()
                } label: {
                    SkipArrows(direction: .forward, height: 14, trigger: nextPresses)
                }
                .buttonStyle(BarIconButtonStyle(diameter: 36))
                .help("Next (⌘→)")
                .accessibilityLabel("Next")
            }

            if let duration = track.duration, duration > 0 {
                BarScrubber(duration: duration, showsTimes: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.55), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    private var nothingPlaying: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Nothing Playing")
                .font(.headline)
            Button("Play Tracks Radio", systemImage: "dot.radiowaves.left.and.right") { player.playTracksRadio() }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }
}

/// A small round button on the cover: a dark glass circle, brighter under the pointer.
private struct MiniWindowButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(isHovering ? 1 : 0.85))
            .frame(width: 24, height: 24)
            .background(.black.opacity(configuration.isPressed ? 0.6 : isHovering ? 0.5 : 0.35), in: .circle)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            // A bigger target than the circle, as the Mac's are.
            .frame(width: 28, height: 28)
            .contentShape(.circle)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.13), value: isHovering)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

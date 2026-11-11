import SwiftUI
import AVFoundation
import TracksCore

/// Albums' animated covers, the square loops Apple Music plays in place of a cover, from a
/// music server that finds them (Octo does, by album name, for any album). Asked of the song's
/// own server first, then the others; a server that can't answer isn't asked again this
/// session. What each album has is kept, none included, so a song coming round again is free.
@MainActor
enum MotionCovers {
    /// Whether Full Cover plays a moving cover where there is one. On by default, as Music's
    /// Animated Art is.
    static let storageKey = "nowPlayingAnimatedCovers"

    private static var found: [String: URL?] = [:]
    private static var asking: [String: Task<URL?, Never>] = [:]
    private static var unable: Set<String> = []

    static func url(for track: PlayerTrack, servers: MusicServers?) async -> URL? {
        #if DEBUG
        // `-TracksDemoMotionCover <address>`: that loop for every song, to see it without a server.
        if let demo = UserDefaults.standard.string(forKey: "TracksDemoMotionCover") { return URL(string: demo) }
        #endif
        guard let servers, let album = track.albumTitle ?? track.local?.album, !album.isEmpty else { return nil }
        let artist = track.local?.albumArtist ?? track.artistName
        let key = "\(StatsCalculator.folded(artist))|\(StatsCalculator.folded(album))"
        if let known = found[key] { return known }
        if let task = asking[key] { return await task.value }
        var clients = servers.servers.compactMap { server in servers.client(for: server.id).map { (server.id, $0) } }
            .filter { !unable.contains($0.0) }
        if case .server(let own, _) = track.local?.origin, let index = clients.firstIndex(where: { $0.0 == own }) {
            clients.insert(clients.remove(at: index), at: 0)
        }
        guard !clients.isEmpty else { return nil }
        let task = Task<URL?, Never> {
            for (id, client) in clients {
                do {
                    return try await client.animatedCover(artist: artist, album: album)
                } catch {
                    unable.insert(id)
                }
            }
            return nil
        }
        asking[key] = task
        let url = await task.value
        asking[key] = nil
        found[key] = url
        return url
    }
}

/// A moving cover, looping silently over the still one, as Music's animated album art does. It
/// fades in once its first frame is ready, so the still cover never blinks out, and holds
/// still while the music's paused, under Reduce Motion, and off screen.
struct MotionCoverView: View {
    let url: URL
    let isPlaying: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isOnScreen) private var isOnScreen
    @State private var isReady = false

    var body: some View {
        LoopingVideo(url: url, isRunning: isPlaying && !reduceMotion && isOnScreen) {
            withAnimation(.easeInOut(duration: 0.6)) { isReady = true }
        }
        .opacity(isReady ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A video looping silently, filling its frame, on its own layer so playing it never redraws
/// SwiftUI.
private struct LoopingVideo {
    let url: URL
    let isRunning: Bool
    let onReady: @MainActor @Sendable () -> Void

    @MainActor
    final class Coordinator {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private var watch: NSKeyValueObservation?
        private var url: URL?

        init() {
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        func load(_ url: URL, into layer: AVPlayerLayer, onReady: @escaping @MainActor @Sendable () -> Void) {
            guard url != self.url else { return }
            self.url = url
            // The view stays as the song changes. The last album's looper is let go first:
            // its copies of the old loop would otherwise stay queued ahead of the new one,
            // and play first, in the one player the two share.
            looper?.disableLooping()
            player.removeAllItems()
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            watch = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor in onReady() }
            }
        }

        func run(_ isRunning: Bool) {
            if isRunning { player.play() } else { player.pause() }
        }

        func stop() {
            watch = nil
            looper?.disableLooping()
            player.pause()
            player.removeAllItems()
        }
    }
}

#if os(macOS)
extension LoopingVideo: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = context.coordinator.player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.load(url, into: view.playerLayer, onReady: onReady)
        context.coordinator.run(isRunning)
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
#else
extension LoopingVideo: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = context.coordinator.player
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.load(url, into: view.playerLayer, onReady: onReady)
        context.coordinator.run(isRunning)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            playerLayer.videoGravity = .resizeAspectFill
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif

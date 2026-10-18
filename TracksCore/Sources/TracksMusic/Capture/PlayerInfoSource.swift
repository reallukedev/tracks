#if os(macOS)
import Foundation
import Synchronization
import TracksCore

/// Observes Music.app on macOS through its `com.apple.Music.playerInfo` distributed
/// notification. `SystemMusicPlayer` is unavailable on macOS, so this is the only way to see
/// what Music.app is playing.
///
/// - Music posts every event twice, as `com.apple.Music.playerInfo` and
///   `com.apple.iTunes.playerInfo`, with identical `userInfo`. We observe one.
/// - Delivery is suspended while the app is inactive, which a menu bar app nearly always
///   is, so this registers with `.deliverImmediately`.
public final class PlayerInfoSource: NSObject, NowPlayingSource, Sendable {
    private struct State {
        var isObserving = false
        /// Where observations go. Replaced on every ``start()``, cleared by ``stop()``.
        var continuation: AsyncStream<NowPlayingObservation>.Continuation?
    }

    /// Guarded because notifications, `start()` and `stop()` needn't arrive on one thread.
    private let state = Mutex(State())

    /// Gets every raw payload, flattened to strings, so the probe can dump it.
    private let onRawNotification: (@Sendable ([String: String]) -> Void)?

    public init(onRawNotification: (@Sendable ([String: String]) -> Void)? = nil) {
        self.onRawNotification = onRawNotification
        super.init()
    }

    @discardableResult
    public func start() -> AsyncStream<NowPlayingObservation> {
        let (stream, continuation) = AsyncStream<NowPlayingObservation>.makeStream()
        let wasObserving = state.withLock { state in
            state.continuation?.finish()
            state.continuation = continuation
            defer { state.isObserving = true }
            return state.isObserving
        }
        if !wasObserving {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(handle(_:)),
                name: Notification.Name(MusicNotificationName.preferred),
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        return stream
    }

    public func stop() {
        let (wasObserving, continuation) = state.withLock { state in
            defer {
                state.isObserving = false
                state.continuation = nil
            }
            return (state.isObserving, state.continuation)
        }
        if wasObserving {
            DistributedNotificationCenter.default().removeObserver(self)
        }
        continuation?.finish()
    }

    @objc private func handle(_ notification: Notification) {
        // Flatten before anything crosses an isolation boundary.
        deliver(ProbeFormat.flatten(notification.userInfo ?? [:]))
    }

    /// Everything a notification does once its payload is flattened. Split out so tests can
    /// drive it without posting a system-wide notification.
    func deliver(_ payload: [String: String]) {
        onRawNotification?(payload)
        guard let observation = Self.observation(from: payload) else { return }
        state.withLock { $0.continuation }?.yield(observation)
    }

    /// A one-shot read of what Music.app is playing, for the App Intent, which can't wait for
    /// the next notification. Any property can fail to read; see ``MusicScripting``.
    public static func currentObservation() -> NowPlayingObservation? {
        let readings = MusicScripting.readAll()
        func value(_ property: String) -> String? {
            guard let reading = readings.first(where: { $0.property == property }),
                  let value = reading.value,
                  value != "missing value",
                  !value.isEmpty
            else { return nil }
            return value
        }

        guard let title = value("name of current track"),
              let artist = value("artist of current track")
        else { return nil }

        return NowPlayingObservation(
            title: title,
            artistName: artist,
            albumTitle: value("album of current track"),
            catalogSongID: nil,
            // No duration means radio on macOS.
            duration: value("duration of current track").flatMap(Double.init),
            playbackState: playbackState(value("player state")?.capitalized),
            playerPosition: value("player position").flatMap(Double.init),
            rawFields: Dictionary(
                readings.compactMap { r in r.value.map { (r.property, $0) } },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    /// Maps the notification payload to an observation.
    ///
    /// `catalogSongID` is always nil because the macOS 27 payload has no catalog id. Identity
    /// comes later from ``CatalogLookup``, which also matches on duration.
    static func observation(from userInfo: [String: String]) -> NowPlayingObservation? {
        let state = playbackState(userInfo[PlayerInfoKey.playerState])
        let title = userInfo[PlayerInfoKey.name] ?? ""
        let artist = userInfo[PlayerInfoKey.artist] ?? ""

        // Music omits zero-valued integer keys and a station track has no length, so a
        // missing Total Time means radio. See RadioHeuristic and
        // docs/PlatformNotes.md.
        let duration: TimeInterval? = userInfo[PlayerInfoKey.totalTime]
            .flatMap { Double($0) }
            .map { $0 / 1000 }

        // Which keys are present matters too, so keep the payload as is.
        let raw = userInfo

        return NowPlayingObservation(
            title: title,
            artistName: artist,
            albumTitle: userInfo[PlayerInfoKey.album],
            catalogSongID: nil,
            duration: duration,
            playbackState: state,
            observedAt: .now,
            rawFields: raw
        )
    }

    static func playbackState(_ value: String?) -> PlaybackState {
        // Music reports fast-forward and rewind as "Stopped", so only these three appear.
        switch value {
        case "Playing": .playing
        case "Paused": .paused
        default: .stopped
        }
    }
}
#endif

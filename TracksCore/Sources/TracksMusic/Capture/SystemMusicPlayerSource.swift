#if os(iOS)
import Foundation
import MusicKit
import Observation
import Synchronization
import TracksCore

/// Observes the system music player on iOS.
///
/// Uses `Observations` on `MusicPlayer.Queue`, which is `Observable` since 26.4. The queue's
/// `currentEntry` hasn't updated yet when the change fires, hence
/// ``MusicPlayerReading/settleDelay``.
@MainActor
public final class SystemMusicPlayerSource: NowPlayingSource {
    /// Where observations go: set by ``start()``, cleared by ``stop()``. Behind a lock
    /// because both are nonisolated and must hand back or finish a stream straight away,
    /// before the main actor gets round to the observation task.
    private nonisolated let continuation = Mutex<AsyncStream<NowPlayingObservation>.Continuation?>(nil)
    private var task: Task<Void, Never>?

    public init() {}

    public nonisolated func start() -> AsyncStream<NowPlayingObservation> {
        let (stream, continuation) = AsyncStream<NowPlayingObservation>.makeStream()
        self.continuation.withLock { current in
            current?.finish()
            current = continuation
        }
        Task { @MainActor in self.reconcile() }
        return stream
    }

    public nonisolated func stop() {
        continuation.withLock { current in
            current?.finish()
            current = nil
        }
        Task { @MainActor in self.reconcile() }
    }

    /// Starts or ends the observation task to match whether a stream is open.
    ///
    /// Reads the wanted state rather than acting on each call, so a stop and a start queued
    /// close together end up right whichever order the main actor runs them in.
    private func reconcile() {
        let wantsObserving = continuation.withLock { $0 != nil }
        if wantsObserving, task == nil {
            startObserving()
        } else if !wantsObserving, let task {
            task.cancel()
            self.task = nil
        }
    }

    private func startObserving() {
        let player = SystemMusicPlayer.shared
        task = Task { @MainActor [weak self] in
            let changes = Observations { player.queue.currentEntry?.id }
            for await _ in changes {
                if Task.isCancelled { return }
                try? await Task.sleep(for: MusicPlayerReading.settleDelay)
                guard let self else { return }
                guard let observation = Self.observation(from: player) else { continue }
                self.continuation.withLock { $0 }?.yield(observation)
            }
        }
    }

    /// A one-shot read of what's playing, for the App Intent. On iOS the capture loop usually
    /// isn't running, so it can't wait for the next queue change.
    public static func currentObservation() -> NowPlayingObservation? {
        observation(from: SystemMusicPlayer.shared)
    }

    static func observation(from player: SystemMusicPlayer) -> NowPlayingObservation? {
        MusicPlayerReading.observation(
            from: player.queue.currentEntry,
            status: player.state.playbackStatus,
            playbackTime: player.playbackTime
        )
    }

    /// The station name ("Apple Music Chill"), when a queue change has just announced one.
    /// This unresolved entry title is the only source of a station name on iOS.
    static func announcedStation(from player: SystemMusicPlayer) -> String? {
        guard let entry = player.queue.currentEntry,
              entry.item == nil,
              entry.subtitle == nil,
              QueueEntryIdentifier(entry.id)?.isStream == true
        else { return nil }
        return entry.title
    }
}
#endif

import Foundation
#if os(iOS)
import UIKit
#endif

/// Holds work for Tracks’ Apple Music player back while a scene changes state, and for a
/// moment after.
///
/// The player reaches Apple's player service over a connection that lapses when the service
/// quits, as it can while the phone sits locked. The next call to the player opens it again on
/// the main thread and waits there for the service to start, which has taken over ten seconds.
/// Inside a scene update (opening, leaving and its snapshot, the car connecting) iOS ends an
/// app whose main thread is held that long, so player work waits until the scene has settled.
///
/// Nothing holds on the Mac, where work runs straight away.
@MainActor
public enum PlayerQuiet {
    /// Long enough for a scene update, and the snapshot after leaving, to finish.
    static let window: Duration = .seconds(2)

    private static var until: ContinuousClock.Instant?
    private static var held: [Held] = []
    private static var release: Task<Void, Never>?
    private static var observers: [any NSObjectProtocol] = []

    private enum Held {
        case work(@MainActor () -> Void)
        case waiter(CheckedContinuation<Void, Never>)
    }

    /// Whether player work is being held back now.
    public static var isQuiet: Bool {
        guard let until else { return false }
        return ContinuousClock.now < until
    }

    /// Holds player work back for ``window`` from now.
    public static func hold() {
        until = ContinuousClock.now + window
        guard release == nil else { return }
        release = Task {
            // Each scene change moves the end on, so it's checked again after every wait.
            while let until, ContinuousClock.now < until {
                try? await Task.sleep(until: until, clock: .continuous)
            }
            release = nil
            flush()
        }
    }

    /// Runs `work` now, or once the scene has settled, in the order it was asked for.
    public static func run(_ work: @escaping @MainActor () -> Void) {
        guard isQuiet || !held.isEmpty else { return work() }
        held.append(.work(work))
    }

    /// Returns straight away, or once the scene has settled.
    public static func settled() async {
        guard isQuiet || !held.isEmpty else { return }
        await withCheckedContinuation { held.append(.waiter($0)) }
    }

    private static func flush() {
        let ready = held
        held = []
        for item in ready {
            switch item {
            case .work(let work): work()
            case .waiter(let waiter): waiter.resume()
            }
        }
    }

    /// Holds player work back from now, as the app launches, and around every scene's changes
    /// after: the phone's window and the car's. Once per process.
    public static func followScenes() {
        #if os(iOS)
        guard observers.isEmpty else { return }
        hold()
        let changes: [Notification.Name] = [
            UIScene.willConnectNotification,
            UIScene.willEnterForegroundNotification,
            UIScene.didActivateNotification,
            UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification,
        ]
        for name in changes {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { hold() }
            })
        }
        #endif
    }
}

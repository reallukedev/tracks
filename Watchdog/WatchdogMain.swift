import AppKit
import TracksCore

/// Reopens the Mac app when it stops without being quit.
///
/// macOS can end Tracks with no warning: when the disk is nearly full it quits apps to purge
/// their caches, and nothing is written to say so. A menu bar app that's gone looks the same
/// as one that's idle, so listening goes unrecorded until someone notices. The app starts
/// this helper at launch with its process ID, when the person has turned on "Reopen Tracks If
/// It Quits Unexpectedly". When that process ends, ``RunLog`` says whether it was quit on
/// purpose; if not, and nobody was using the Mac at that moment (Force Quit is someone at the
/// Mac), this opens it again, and the app shows what happened.
///
/// It has no interface and does nothing else. It exits once the app it watches has gone,
/// and the reopened app starts a new one.
@main
struct Watchdog {
    static func main() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--watch"),
              arguments.indices.contains(flag + 1),
              let processID = Int32(arguments[flag + 1]),
              let target = NSRunningApplication(processIdentifier: processID),
              let appURL = target.bundleURL
        else { exit(0) }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Nothing here needs saving, so logging out or shutting down never waits on it.
        ProcessInfo.processInfo.enableSuddenTermination()

        let watcher = Watcher(processID: processID, appURL: appURL)
        watcher.start()
        // It may have gone between being asked for and the observer being added.
        if target.isTerminated { watcher.appEnded() }

        withExtendedLifetime(watcher) { app.run() }
    }
}

@MainActor
final class Watcher {
    private let processID: Int32
    private let appURL: URL
    private var observer: NSObjectProtocol?
    private var isHandling = false

    /// Long enough for the app's last write, that it was quit, to reach this process.
    private static let settle: Duration = .seconds(1)
    /// A pause before reopening, so an app that failed at once isn't hammered.
    private static let reopenDelay: Duration = .seconds(2)
    /// An update can still be replacing the app when it's asked to open, so try a few times.
    private static let attempts = 5
    private static let retryDelay: Duration = .seconds(5)

    init(processID: Int32, appURL: URL) {
        self.processID = processID
        self.appURL = appURL
    }

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let ended = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let endedID = ended?.processIdentifier
            let idle = UserPresence.secondsSinceInput
            MainActor.assumeIsolated {
                guard let self, endedID == self.processID else { return }
                self.appEnded(secondsSinceInput: idle)
            }
        }
    }

    /// - Parameter secondsSinceInput: how long the Mac had been left alone as the app ended,
    ///   read at once, since the settle below would add to it.
    func appEnded(secondsSinceInput: TimeInterval? = UserPresence.secondsSinceInput) {
        guard !isHandling else { return }
        isHandling = true
        Task {
            try? await Task.sleep(for: Self.settle)
            let log = RunLog()
            switch log.recordTermination(processID: processID, secondsSinceInput: secondsSinceInput) {
            case .reopen:
                try? await Task.sleep(for: Self.reopenDelay)
                // Turned off in the meantime: respect it.
                guard log.reopensAutomatically else { break }
                await reopen()
            case .quit, .leftClosed, .gaveUp, .unknown:
                break
            }
            exit(0)
        }
    }

    private func reopen() async {
        let configuration = NSWorkspace.OpenConfiguration()
        // Back where it was, in the menu bar, without taking focus from whatever is in front.
        configuration.activates = false
        configuration.addsToRecentItems = false
        for attempt in 1...Self.attempts {
            if (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)) != nil {
                return
            }
            if attempt < Self.attempts { try? await Task.sleep(for: Self.retryDelay) }
        }
    }
}

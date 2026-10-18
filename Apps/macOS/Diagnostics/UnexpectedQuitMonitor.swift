import AppKit
import Observation
import os
import TracksCore

/// Keeps the run log, starts the watchdog, and holds the notice about the last run.
///
/// See ``RunLog`` for how an unexpected quit is recognised and `Watchdog/WatchdogMain.swift`
/// for how the app comes back from one.
@MainActor
@Observable
final class UnexpectedQuitMonitor {
    /// The last run's unexpected end, until the person closes the notice.
    private(set) var notice: UnexpectedQuit?

    @ObservationIgnored private let log = RunLog()
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var isWatched = false
    @ObservationIgnored private var isDebugged = false

    /// "Reopen Tracks If It Quits Unexpectedly". Off until the person turns it on, since the
    /// app coming back by itself should be their choice. The watchdog reads it too.
    var reopensAutomatically: Bool {
        get {
            access(keyPath: \.reopensAutomatically)
            return log.reopensAutomatically
        }
        set {
            withMutation(keyPath: \.reopensAutomatically) { log.reopensAutomatically = newValue }
            if newValue { startWatchdogIfWanted() }
        }
    }

    /// Often enough that a run which ends unseen is placed within a minute.
    private static let heartbeatInterval: Duration = .seconds(60)

    /// Starts this run. Call once, at launch.
    ///
    /// A demo launch keeps no record: it's for screenshots, and a notice would end up in one.
    /// Under a debugger the run is recorded but the watchdog isn't started, so stopping the
    /// app in Xcode doesn't open it again behind the developer's back.
    func start(isDemoLaunch: Bool) {
        guard !isDemoLaunch else { return }

        // Every way of being quit on purpose then goes through `applicationWillTerminate`,
        // which is what marks a run as ended cleanly. Without these, macOS may end an idle app
        // silently at log out, or on its own, and that would read as a crash.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Watched for unexpected quits")

        let info = Bundle.main.infoDictionary
        let debugged = Self.isDebuggerAttached
        isDebugged = debugged
        notice = log.beginRun(
            version: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            processID: ProcessInfo.processInfo.processIdentifier,
            isDebugged: debugged
        )

        heartbeat = Task { [log] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                log.heartbeat()
            }
        }

        startWatchdogIfWanted()
    }

    /// Marks the run as quit on purpose. Call from `applicationWillTerminate`.
    func applicationWillTerminate() {
        heartbeat?.cancel()
        log.endCleanly()
    }

    func dismiss() {
        log.dismissNotice()
        notice = nil
    }

    /// How often the watchdog has reopened the app lately, for the debug report.
    var recentAutomaticReopens: Int { log.recentRelaunches.count }

    /// Starts the watchdog once, when reopening is on and no debugger is attached.
    private func startWatchdogIfWanted() {
        guard log.reopensAutomatically, !isDebugged, !isWatched, heartbeat != nil else { return }
        isWatched = true
        startWatchdog()
    }

    private func startWatchdog() {
        let helper = Bundle.main.bundleURL
            .appending(path: "Contents/Library/LoginItems/TracksWatchdog.app", directoryHint: .isDirectory)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--watch", String(ProcessInfo.processInfo.processIdentifier)]
        configuration.activates = false
        configuration.addsToRecentItems = false
        // The previous run's watchdog can still be finishing up as this one starts. Without a
        // new instance, macOS would hand the request to it and the arguments would be lost.
        configuration.createsNewApplicationInstance = true
        Task {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
            } catch {
                // Nothing to show: the app works without it, it just won't come back on its own.
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tracks", category: "Watchdog")
                    .error("Watchdog didn't start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Whether a debugger is attached, as Apple's Technical Q&A QA1361 describes.
    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

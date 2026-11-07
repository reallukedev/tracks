import Foundation

/// Notices when the Mac app stopped without being quit, so it can say so and be reopened.
///
/// macOS can end a menu bar app with no crash report and no warning: when the disk is nearly
/// full it quits apps to purge their caches, and an update replaces the app underneath it.
/// Either way Tracks stops recording, and nothing on screen says so. Each run leaves a
/// ``RunRecord`` in the App Group's defaults, stamped as it goes and marked clean when the
/// app is quit. A record still open at the next launch is a run that ended some other way.
///
/// The app and the watchdog (see `TracksWatchdog`) share this through the App Group, so
/// the watchdog can say exactly when the app went and whether to reopen it.
public struct RunLog: Sendable {
    static let recordKey = "TracksRunRecord"
    static let noticeKey = "TracksUnexpectedQuit"
    static let relaunchesKey = "TracksWatchdogRelaunches"
    /// Whether the watchdog reopens the app. Off until the person turns it on in Settings.
    public static let reopensKey = "TracksReopensAfterUnexpectedQuit"

    /// Input this recent when the app ended means the person was at the Mac, most likely
    /// ending it themselves with Force Quit. macOS reclaims apps that sit idle.
    public static let recentInput: TimeInterval = 15

    /// How many times the watchdog will reopen the app within ``relaunchWindow``. A crash at
    /// launch would otherwise reopen it forever.
    public static let maxRelaunches = 3
    public static let relaunchWindow: TimeInterval = 10 * 60

    /// The suite name, not the `UserDefaults`, which isn't `Sendable`. See ``CaptureSettings``.
    private let suiteName: String?

    public init(suiteName: String? = AppGroup.identifier) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    // MARK: - The app

    /// Starts this run's record, and reports the previous run if it ended without a quit.
    ///
    /// A previous run is not reported when it was under a debugger, since stopping it in Xcode
    /// kills it, or when this is a different build, since installing an update ends the old
    /// one. The report stays until ``dismissNotice()``, so it survives another launch.
    ///
    /// - Returns: the notice to show, which may be one from an earlier launch not yet dismissed.
    @discardableResult
    public func beginRun(
        version: String,
        build: String,
        processID: Int32,
        isDebugged: Bool,
        now: Date = .now
    ) -> UnexpectedQuit? {
        if let previous = record, !previous.endedCleanly, !previous.isDebugged,
           previous.version == version, previous.build == build {
            let reopened = previous.relaunchedAt != nil
            store(UnexpectedQuit(
                launchedAt: previous.launchedAt,
                stoppedAt: previous.stoppedAt ?? previous.lastSeenAt,
                stopTimeIsExact: previous.stoppedAt != nil,
                reopenedAt: now,
                reopenedAutomatically: reopened,
                version: version,
                build: build
            ), forKey: Self.noticeKey)
        }
        record = RunRecord(
            launchedAt: now,
            lastSeenAt: now,
            version: version,
            build: build,
            processID: processID,
            isDebugged: isDebugged
        )
        return notice
    }

    /// Notes that the app is still running, so a run that ends unseen has a last-known time.
    public func heartbeat(now: Date = .now) {
        guard var current = record else { return }
        current.lastSeenAt = now
        record = current
    }

    /// Marks this run as quit on purpose: by the person, at log out, or at shut down.
    public func endCleanly(now: Date = .now) {
        guard var current = record else { return }
        current.lastSeenAt = now
        current.endedCleanly = true
        record = current
        // The process exits right after this, and the watchdog reads it from another process.
        // A write still on its way to the preferences daemon would read as a crash.
        defaults.synchronize()
    }

    /// The last run's unexpected end, until the person closes the notice about it.
    public var notice: UnexpectedQuit? {
        load(UnexpectedQuit.self, forKey: Self.noticeKey)
    }

    public func dismissNotice() {
        defaults.removeObject(forKey: Self.noticeKey)
    }

    // MARK: - The watchdog

    /// Whether the watchdog should run and reopen the app, as the person chose.
    public var reopensAutomatically: Bool {
        get { defaults.bool(forKey: Self.reopensKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.reopensKey) }
    }

    /// What the watchdog should do now that the app it was watching has gone.
    public enum Termination: Sendable, Equatable {
        /// Quit on purpose. Leave it closed.
        case quit
        /// Ended some other way. Reopen it.
        case reopen
        /// Ended some other way, but reopening is off, or the person was at the Mac and most
        /// likely ended it themselves. Leave it closed.
        case leftClosed
        /// Ended some other way, but it has been reopened too often lately. Leave it closed.
        case gaveUp
        /// Not the run this log knows about, such as an older copy. Leave it alone.
        case unknown
    }

    /// Records that the app with `processID` has ended, and decides whether to reopen it.
    ///
    /// Only the run whose record is current counts: a watchdog left over from an earlier run
    /// mustn't reopen the app because some other copy of it exited.
    ///
    /// - Parameter secondsSinceInput: how long the Mac had been left alone when the app ended,
    ///   if known. Under ``recentInput`` the app stays closed, so Force Quit is respected.
    public func recordTermination(
        processID: Int32,
        secondsSinceInput: TimeInterval? = nil,
        now: Date = .now
    ) -> Termination {
        guard var current = record, current.processID == processID else { return .unknown }
        guard !current.endedCleanly else { return .quit }

        current.stoppedAt = now
        let personWasThere = secondsSinceInput.map { $0 < Self.recentInput } ?? false
        guard reopensAutomatically, !personWasThere else {
            record = current
            return .leftClosed
        }
        let recent = relaunches.filter { now.timeIntervalSince($0) < Self.relaunchWindow }
        guard recent.count < Self.maxRelaunches else {
            record = current
            relaunches = recent
            return .gaveUp
        }
        current.relaunchedAt = now
        record = current
        relaunches = recent + [now]
        return .reopen
    }

    /// When the watchdog has reopened the app lately, for the debug report.
    public var recentRelaunches: [Date] { relaunches }

    // MARK: - Storage

    var record: RunRecord? {
        get { load(RunRecord.self, forKey: Self.recordKey) }
        nonmutating set { store(newValue, forKey: Self.recordKey) }
    }

    private var relaunches: [Date] {
        get { load([Date].self, forKey: Self.relaunchesKey) ?? [] }
        nonmutating set { store(newValue, forKey: Self.relaunchesKey) }
    }

    private func load<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func store(_ value: (some Encodable)?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// One launch of the app, as far as it got.
struct RunRecord: Codable, Sendable, Equatable {
    var launchedAt: Date
    var lastSeenAt: Date
    var version: String
    var build: String
    var processID: Int32
    var isDebugged: Bool
    var endedCleanly = false
    /// When the watchdog saw it end, which is exact where ``lastSeenAt`` is only the last
    /// heartbeat.
    var stoppedAt: Date?
    /// When the watchdog asked for it to be opened again.
    var relaunchedAt: Date?
}

/// A run that ended without being quit, for the notice and the debug report.
public struct UnexpectedQuit: Codable, Sendable, Equatable {
    public let launchedAt: Date
    /// When it stopped. Exact if the watchdog saw it; otherwise the last time it was known to
    /// be running, up to a minute early.
    public let stoppedAt: Date
    public let stopTimeIsExact: Bool
    /// When it was running again.
    public let reopenedAt: Date
    /// Whether the watchdog reopened it, rather than the person or login.
    public let reopenedAutomatically: Bool
    public let version: String
    public let build: String

    /// How long nothing was being recorded.
    public var gap: TimeInterval { reopenedAt.timeIntervalSince(stoppedAt) }
}

import Foundation
import Observation
import TracksCore
#if os(iOS)
import AVFoundation
import CoreMotion
import UIKit
#endif

/// Notices when you're driving, for Tracks Radio's Drive mode and Louder at Speed: from how
/// iPhone moves (Motion & Fitness), or CarPlay.
///
/// Nothing is asked until Tracks Radio starts with Notice When You're Driving on, or Louder at
/// Speed is turned on. Once Motion & Fitness is allowed it listens whenever Tracks runs, and
/// remembers each drive on this iPhone, so the radio knows the songs you play on the road. The
/// Mac never drives, and there it stays off.
@MainActor
@Observable
final class DriveDetector {
    enum Access: Equatable {
        /// Motion & Fitness hasn't been asked for yet.
        case notAsked
        case allowed
        /// Turned off for Tracks in Settings, or by restrictions: only CarPlay counts.
        case denied
        /// No motion to sense, as on a Mac.
        case unavailable
    }

    private(set) var isDriving = false
    private(set) var access: Access
    /// Called as a drive starts or ends, for the radio to follow.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The drives noticed on this iPhone.
    @ObservationIgnored private(set) var log: DriveLog

    private static let logKey = "tracksRadioDrives"

    #if os(iOS)
    @ObservationIgnored private let motion = CMMotionActivityManager()
    @ObservationIgnored private var sense = DriveSense()
    /// Listening for CarPlay, which needs no permission.
    @ObservationIgnored private var isListeningForCarPlay = false
    /// Sensing motion, once Motion & Fitness is asked for or allowed.
    @ObservationIgnored private var isSensingMotion = false
    @ObservationIgnored private var hasLookedBack = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Ends a drive once the car has been still long enough: Core Motion says nothing more
    /// while nothing changes.
    @ObservationIgnored private var lingerCheck: Task<Void, Never>?
    #endif

    init() {
        log = DriveLog(stored: UserDefaults.standard.data(forKey: Self.logKey))
        access = Self.currentAccess
        isDriving = Self.isDemoDriving
    }

    /// `-TracksDemoDriving YES` drives from launch, for screenshots of Tracks Radio on the road.
    /// Debug builds only.
    private static var isDemoDriving: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "TracksDemoDriving")
        #else
        false
        #endif
    }

    /// Starts listening, asking for Motion & Fitness the first time: for Tracks Radio starting
    /// with the setting on, or Louder at Speed turned on.
    func start() {
        #if os(iOS)
        guard PlayPreferences.noticesDriving else { return }
        listenForCarPlay()
        guard !isSensingMotion, CMMotionActivityManager.isActivityAvailable(), access != .denied else { return }
        isSensingMotion = true
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let reading = DriveSense.Reading(activity)
            MainActor.assumeIsolated { self?.take(reading) }
        }
        lookBack()
        #endif
    }

    /// At launch: senses motion only when Motion & Fitness is already allowed, so nothing is
    /// asked. CarPlay needs no asking, so it counts from the start.
    func resumeIfAllowed() {
        #if os(iOS)
        guard PlayPreferences.noticesDriving else { return }
        if access == .allowed { start() } else { listenForCarPlay() }
        #endif
    }

    /// For a setting turned off: stops listening once nothing needs it, and any drive under
    /// way ends here.
    func stopIfUnneeded() {
        #if os(iOS)
        guard isListeningForCarPlay || isSensingMotion, !PlayPreferences.noticesDriving else { return }
        isListeningForCarPlay = false
        isSensingMotion = false
        motion.stopActivityUpdates()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        lingerCheck?.cancel()
        if let start = sense.driveStart { remember(DateInterval(start: start, end: max(start, .now))) }
        sense = DriveSense()
        update()
        #endif
    }

    private static var currentAccess: Access {
        #if os(iOS)
        guard CMMotionActivityManager.isActivityAvailable() else { return .unavailable }
        return switch CMMotionActivityManager.authorizationStatus() {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        #else
        .unavailable
        #endif
    }

    #if os(iOS)
    private func take(_ reading: DriveSense.Reading) {
        // A reading arriving means the answer to the prompt was yes. The week before is read
        // now: at start() it couldn't be, not yet allowed.
        if access != .allowed {
            access = .allowed
            lookBack()
        }
        if let drive = sense.take(reading) { remember(drive) }
        update()
    }

    /// CarPlay, by the audio going to the car or Tracks’ own CarPlay screen being up.
    private func checkCarPlay() {
        let isConnected = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
            || UIApplication.shared.connectedScenes.contains { $0.session.role == .carTemplateApplication }
        if let drive = sense.carPlay(isConnected: isConnected, at: .now) { remember(drive) }
        update()
    }

    private func listenForCarPlay() {
        guard !isListeningForCarPlay else { return }
        isListeningForCarPlay = true
        let center = NotificationCenter.default
        let changes: [Notification.Name] = [
            AVAudioSession.routeChangeNotification,
            UIScene.willConnectNotification,
            UIScene.didDisconnectNotification,
        ]
        for name in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkCarPlay() }
            })
        }
        // Motion & Fitness may have been answered, or changed in Settings, while away.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        })
        checkCarPlay()
    }

    private func becameActive() {
        let wasAllowed = access == .allowed
        access = Self.currentAccess
        if access == .allowed, !wasAllowed {
            // Allowed in Settings while away: start sensing, as if it had been allowed here.
            start()
            lookBack()
        }
        checkCarPlay()
    }

    /// Reads the last week of motion once a launch, for drives Tracks wasn't running for.
    private func lookBack() {
        guard !hasLookedBack, access == .allowed else { return }
        hasLookedBack = true
        let end = Date.now
        motion.queryActivityStarting(from: end.addingTimeInterval(-7 * 24 * 60 * 60), to: end, to: .main) { [weak self] activities, _ in
            let readings = (activities ?? []).map(DriveSense.Reading.init)
            MainActor.assumeIsolated { self?.remember(DriveSense.drives(in: readings, until: end), until: end) }
        }
    }

    /// Drives found looking back. The one under way, if there is one, is the live sense's to
    /// finish.
    private func remember(_ drives: [DateInterval], until end: Date) {
        for drive in drives where drive.end < end {
            log.record(drive, now: end)
        }
        save()
    }

    private func remember(_ drive: DateInterval) {
        log.record(drive, now: .now)
        save()
    }

    private func save() {
        UserDefaults.standard.set(log.stored, forKey: Self.logKey)
    }

    /// Publishes a change of driving, and sets the timer for when a stop would end the drive.
    private func update() {
        lingerCheck?.cancel()
        if let endsAt = sense.endsAt {
            lingerCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, endsAt.timeIntervalSinceNow + 1)))
                guard !Task.isCancelled, let self else { return }
                if let drive = sense.check(at: .now) { remember(drive) }
                update()
            }
        }
        let driving = sense.isDriving || Self.isDemoDriving
        guard driving != isDriving else { return }
        isDriving = driving
        onChange?()
    }
    #endif
}

#if os(iOS)
extension DriveSense.Reading {
    init(_ activity: CMMotionActivity) {
        self.init(
            date: activity.startDate,
            isAutomotive: activity.automotive,
            isOnFoot: activity.walking || activity.running || activity.cycling,
            isConfident: activity.confidence != .low
        )
    }
}
#endif

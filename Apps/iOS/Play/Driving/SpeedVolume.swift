import AVFoundation
import CoreLocation
import TracksCore
import UIKit

/// Louder at Speed: while you drive, the music comes up as the car speeds up and eases down as
/// it slows, so it's as loud as the road on the highway and quiet enough to talk over at the
/// lights, as a car's own speed-sensitive volume is. ``SpeedLoudness`` decides the level and
/// how it moves; this follows the car and the player and sets it.
///
/// Your own music is set on Tracks’ own player level, under the volume you set, so your volume
/// is the highway's and the music comes down from it as you slow. Apple Music plays in the
/// system's player, whose level only iPhone's volume changes, so there Tracks moves iPhone's
/// volume, a half-step at a time (see ``SystemVolume``). Over CarPlay the car keeps its volume
/// to itself, so Apple Music can't follow there.
///
/// Location is used only while driving with something to play, and only the speed is read.
@MainActor
@Observable
final class SpeedVolume {
    static let shared = SpeedVolume()

    /// The setting. Changed here, so the drive and the page follow it at once.
    private(set) var isOn: Bool
    private(set) var amount: SpeedVolumeAmount

    private(set) var authorization: CLAuthorizationStatus
    /// Precise Location on: Approximate Location has no speed in it.
    private(set) var isPrecise: Bool
    /// The audio is going to CarPlay.
    private(set) var isOnCarPlay: Bool
    /// Driving with music on, and the speed coming in.
    private(set) var isFollowing = false
    /// The car's speed while following, in metres a second, and where the music is, in decibels
    /// under your highway volume: for the page's curve to show where you are on it.
    private(set) var speed: Double?
    private(set) var level: Double = 0

    enum Output: Equatable {
        /// Tracks’ own player level: your own music.
        case playerLevel
        /// iPhone's volume: Apple Music.
        case systemVolume
    }

    /// What the drive needs from here, from everything it depends on.
    private struct Situation: Equatable {
        var isOn = false
        var isDriving = false
        var hasQueue = false
        var isPlaying = false
        var output = Output.playerLevel
        var hasAccess = false
        var isOnCarPlay = false

        /// Whether the music should be following the car.
        var engages: Bool {
            isOn && isDriving && hasQueue && hasAccess && !(output == .systemVolume && isOnCarPlay)
        }
    }

    @ObservationIgnored private let access = LocationAccess()
    @ObservationIgnored private let systemVolume = SystemVolume()
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var loudness: SpeedLoudness
    @ObservationIgnored private var situation = Situation()
    @ObservationIgnored private var isEngaged = false
    @ObservationIgnored private var output = Output.playerLevel
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var ticking: Task<Void, Never>?
    /// Stops listening a while after the music pauses, so a pause for a call doesn't lose the
    /// speed, and a long one doesn't keep location on.
    @ObservationIgnored private var pauseGrace: Task<Void, Never>?
    @ObservationIgnored private var serviceSession: CLServiceSession?
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Motion & Fitness is asked for once Location has been answered, so the two prompts come
    /// one after the other rather than on top of each other.
    @ObservationIgnored private var asksForMotionNext = false
    @ObservationIgnored private var lastPlayerLevel: Float = 1

    static let askedForAlwaysKey = "speedVolumeAskedForAlways"

    private init() {
        let amount = PlayPreferences.speedVolumeAmount
        isOn = PlayPreferences.volumeFollowsSpeed
        self.amount = amount
        authorization = access.manager.authorizationStatus
        isPrecise = access.manager.accuracyAuthorization == .fullAccuracy
        isOnCarPlay = SystemVolume.isOnCarPlay
        loudness = SpeedLoudness(amount: amount)
        access.onChange = { [weak self] in self?.accessChanged() }
    }

    // MARK: - The setting

    func setOn(_ isOn: Bool) {
        guard isOn != self.isOn else { return }
        self.isOn = isOn
        UserDefaults.standard.set(isOn, forKey: PlayPreferences.volumeFollowsSpeedKey)
        guard let drive = model?.player.drive else { return }
        if isOn {
            // Asked from the switch, while someone's looking at the phone rather than the road.
            if authorization == .notDetermined {
                asksForMotionNext = true
                access.manager.requestWhenInUseAuthorization()
            } else {
                drive.start()
            }
        } else {
            drive.stopIfUnneeded()
        }
    }

    func setAmount(_ amount: SpeedVolumeAmount) {
        guard amount != self.amount else { return }
        self.amount = amount
        UserDefaults.standard.set(amount.rawValue, forKey: PlayPreferences.speedVolumeAmountKey)
        loudness.amount = amount
        tick()
    }

    /// Asks to change Location to Always, so it starts with iPhone in a pocket. iPhone asks
    /// only once; after that it's changed in Settings.
    /// - Returns: whether iPhone will ask. When it won't, Settings is the place to change it.
    func askForAlways() -> Bool {
        guard authorization == .authorizedWhenInUse, !UserDefaults.standard.bool(forKey: Self.askedForAlwaysKey) else { return false }
        UserDefaults.standard.set(true, forKey: Self.askedForAlwaysKey)
        access.manager.requestAlwaysAuthorization()
        return true
    }

    /// Asks for Location, for a page opened with the setting on but never asked.
    func askForLocation() {
        guard authorization == .notDetermined else { return }
        asksForMotionNext = true
        access.manager.requestWhenInUseAuthorization()
    }

    var hasAskedForAlways: Bool { UserDefaults.standard.bool(forKey: Self.askedForAlwaysKey) }

    // MARK: - Following the drive

    /// Follows the setting, the drive, the player and the audio route from launch on.
    func start(_ model: AppModel) {
        guard watching == nil else { return }
        self.model = model
        let player = model.player
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.routeChanged() }
        })
        // Access changed in Settings while away; and a drive that started with Tracks in the
        // background can keep its speed coming once Tracks is in use again.
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            })
        }
        watching = Task { [weak self] in
            let situations = Observations { [weak self] in
                Situation(
                    isOn: self?.isOn ?? false,
                    isDriving: player.drive.isDriving,
                    hasQueue: player.hasQueue,
                    isPlaying: player.isPlaying,
                    output: player.setsOwnLevel ? .playerLevel : .systemVolume,
                    hasAccess: self?.hasAccess ?? false,
                    isOnCarPlay: self?.isOnCarPlay ?? false
                )
            }
            for await situation in situations {
                self?.follow(situation)
            }
        }
    }

    private var hasAccess: Bool {
        (authorization == .authorizedWhenInUse || authorization == .authorizedAlways) && isPrecise
    }

    private func follow(_ new: Situation) {
        guard new != situation else { return }
        situation = new
        guard new.engages else {
            if isEngaged { disengage() }
            return
        }
        if !isEngaged {
            engage(new.output)
        } else if new.output != output {
            switchOutput(to: new.output)
        }
        if new.isPlaying {
            pauseGrace?.cancel()
            pauseGrace = nil
            listen()
        } else if listening != nil, pauseGrace == nil {
            pauseGrace = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { return }
                pauseGrace = nil
                stopListening()
            }
        } else if listening == nil {
            // A drive noticed with the music paused: listen a while anyway, so the level is
            // right for the road before the music starts, not a moment after.
            listen()
            pauseGrace = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard !Task.isCancelled, let self else { return }
                pauseGrace = nil
                if !situation.isPlaying { stopListening() }
            }
        }
    }

    private func engage(_ output: Output) {
        isEngaged = true
        self.output = output
        // From wherever the music is now: full, or partway back from the last drive.
        loudness = SpeedLoudness(amount: amount, level: loudness.level)
        systemVolume.forget()
    }

    private func disengage() {
        isEngaged = false
        pauseGrace?.cancel()
        pauseGrace = nil
        stopListening()
        switch output {
        case .playerLevel:
            // Back up to your volume, as it would pulling away.
            loudness.release()
            tick()
        case .systemVolume:
            // iPhone's volume is yours now: it stays where it is, rather than jumping as you
            // park. The next drive starts from it.
            loudness = SpeedLoudness(amount: amount)
            systemVolume.forget()
        }
    }

    /// The music source changed mid-drive.
    private func switchOutput(to new: Output) {
        if output == .playerLevel {
            // Your own music's player is left at full for when it's next used.
            setPlayerLevel(1)
        }
        output = new
        systemVolume.forget()
        tick()
    }

    private func listen() {
        guard listening == nil else { return }
        serviceSession = CLServiceSession(authorization: .whenInUse)
        // Keeps the speed coming with iPhone locked in a pocket, for this drive only.
        backgroundSession = CLBackgroundActivitySession()
        listening = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    if update.stationary {
                        hear(0)
                    } else if let location = update.location, Self.hasTrustworthySpeed(location) {
                        hear(location.speed)
                    }
                }
            } catch {
                return
            }
        }
    }

    /// A speed to go by: within 5 m/s when the fix says how sure it is, or from a good fix
    /// when it doesn't, as some cars' own GPS over CarPlay doesn't.
    private static func hasTrustworthySpeed(_ location: CLLocation) -> Bool {
        guard location.speed >= 0 else { return false }
        if location.speedAccuracy >= 0 { return location.speedAccuracy < 5 }
        return location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 50
    }

    private func stopListening() {
        listening?.cancel()
        listening = nil
        serviceSession = nil
        backgroundSession?.invalidate()
        backgroundSession = nil
        isFollowing = false
        speed = nil
    }

    private func hear(_ metresPerSecond: Double) {
        guard isEngaged else { return }
        loudness.hear(speed: metresPerSecond, at: .now)
        let isPlaying = situation.isPlaying
        if !isPlaying {
            // Nothing is heard to move: be at the road's level before the music starts.
            loudness.settle()
        }
        if output == .systemVolume, !systemVolume.isAnchored {
            // The volume you have as the drive starts is right for the speed you're at.
            loudness.settle()
            systemVolume.anchor(at: loudness.level)
        }
        if !isFollowing { isFollowing = true }
        speed = loudness.speed
        tick()
    }

    /// Moves the music ten times a second until it's where it's heading, then rests.
    private func tick() {
        guard ticking == nil else { return }
        ticking = Task { [weak self] in
            while let self, !Task.isCancelled {
                loudness.advance(to: .now)
                apply()
                if loudness.isSettled { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self?.ticking = nil
        }
    }

    private func apply() {
        // The page's curve needs a tenth of a decibel, not every step.
        if abs(level - loudness.level) >= 0.1 || (loudness.isSettled && level != loudness.level) {
            level = loudness.level
        }
        switch output {
        case .playerLevel:
            setPlayerLevel(Float(SpeedLoudness.amplitude(decibels: loudness.level)))
        case .systemVolume:
            guard isEngaged else { return }
            systemVolume.follow(loudness.level)
        }
    }

    private func setPlayerLevel(_ value: Float) {
        guard abs(value - lastPlayerLevel) >= 0.002 || (value == 1 && lastPlayerLevel != 1) else { return }
        lastPlayerLevel = value
        model?.player.setLevel(value)
    }

    // MARK: - Access and the route

    private func accessChanged() {
        authorization = access.manager.authorizationStatus
        isPrecise = access.manager.accuracyAuthorization == .fullAccuracy
        if asksForMotionNext, authorization != .notDetermined {
            asksForMotionNext = false
            if isOn { model?.player.drive.start() }
        }
    }

    private func becameActive() {
        accessChanged()
        isOnCarPlay = SystemVolume.isOnCarPlay
        // A session started in the background never became active: now it can.
        if listening != nil {
            backgroundSession?.invalidate()
            backgroundSession = CLBackgroundActivitySession()
        }
    }

    private func routeChanged() {
        isOnCarPlay = SystemVolume.isOnCarPlay
        // Other speakers keep their own volume: start again from theirs.
        systemVolume.forget()
    }
}

/// Hears Location's answers and changes, on the main thread the manager was made on.
@MainActor
private final class LocationAccess: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { onChange?() }
    }
}

extension SpeedVolume {
    /// Where it stands, for its settings page and its row on the Play page.
    func standing(motion: DriveDetector.Access, isAppleMusic: Bool) -> SpeedVolumeStanding {
        let location: SpeedVolumeStanding.Location = switch authorization {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whileUsing
        case .denied: .off
        case .restricted: .restricted
        default: .notAsked
        }
        let motion: SpeedVolumeStanding.Motion = switch motion {
        case .notAsked: .notAsked
        case .allowed: .on
        case .denied: .off
        case .unavailable: .unavailable
        }
        return SpeedVolumeStanding(
            isOn: isOn,
            amount: amount,
            location: location,
            isPrecise: isPrecise,
            motion: motion,
            isAppleMusic: isAppleMusic,
            isOnCarPlay: isOnCarPlay,
            isFollowing: isFollowing
        )
    }
}


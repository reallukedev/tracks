#if os(iOS)
import AVFoundation
import AVKit
import Observation
import TracksCore

/// Where this iPhone's sound is going, and whether there's anywhere else for it to go, while
/// Your Devices is open. Both come from the system as they change; nothing is polled.
///
/// Route detection keeps the radio looking for AirPlay devices, so it runs only while
/// someone's looking.
@MainActor
@Observable
final class SpeakerRouteObserver {
    private(set) var route: SpeakerRoute?
    /// Somewhere besides the iPhone to play to: an AirPlay speaker, a TV, headphones.
    private(set) var hasOtherRoutes = false

    @ObservationIgnored private let detector = AVRouteDetector()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var sample: SpeakerRoute?

    init() {
        #if DEBUG
        // `-TracksSpeakersDemo YES` (or `group`) with demo data: playing on a HomePod, for
        // screenshots, as the simulator has none.
        if DemoMode.isRequestedAtLaunch, let mode = UserDefaults.standard.string(forKey: "TracksSpeakersDemo") {
            sample = SpeakerRoute(kind: .airPlay, names: mode == "group" ? ["Kitchen", "Living Room"] : ["Kitchen"])
        }
        #endif
    }

    func start() {
        guard observers.isEmpty else { return }
        if let sample {
            route = sample
            hasOtherRoutes = true
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.readRoute() }
        })
        observers.append(center.addObserver(forName: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.readDetector() }
        })
        detector.isRouteDetectionEnabled = true
        readRoute()
        readDetector()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        detector.isRouteDetectionEnabled = false
    }

    private func readRoute() {
        let read = Self.currentRoute
        if read != route { route = read }
    }

    private func readDetector() {
        if detector.multipleRoutesDetected != hasOtherRoutes { hasOtherRoutes = detector.multipleRoutesDetected }
    }

    /// The audio session's outputs, read as they stand.
    static var currentRoute: SpeakerRoute? {
        SpeakerRoute(outputs: AVAudioSession.sharedInstance().currentRoute.outputs.map { (type: $0.portType.rawValue, name: $0.portName) })
    }
}
#endif

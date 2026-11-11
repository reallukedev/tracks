import AVFoundation
import CoreAudio
import Foundation
import Observation
import TracksCore

/// Where the Mac's sound is going: the output chosen in Control Center's Sound module or the
/// AirPlay button, which is where Tracks' own player is heard.
enum SystemOutput {
    /// The output now, nil for the Mac's own speakers.
    static var current: NearbySpeakers? { read()?.speakers }

    /// The output's own name, "MacBook Pro Speakers" or "A Home's Pod", and what it is.
    static func read() -> (name: String, speakers: NearbySpeakers?)? {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown
        else { return nil }

        address.mSelector = kAudioObjectPropertyName
        var cfName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &cfName) == noErr,
              let name = cfName?.takeRetainedValue() as String?
        else { return nil }

        address.mSelector = kAudioDevicePropertyTransportType
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
        return (name, NearbySpeakers(outputName: name, transport: transport))
    }

    fileprivate static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// Calls back on the main actor each time the Mac's output changes, until it's stopped.
/// Core Audio says so itself, so nothing is polled.
final class SystemOutputFollower {
    private let listener: AudioObjectPropertyListenerBlock
    private var isListening = false

    init(_ changed: @escaping @MainActor @Sendable () -> Void) {
        listener = Self.listener(changed)
        var address = SystemOutput.defaultOutputAddress
        isListening = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr
    }

    /// Made outside the main actor: Core Audio runs it on the main queue, as it's asked to.
    private nonisolated static func listener(_ changed: @escaping @MainActor @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { _, _ in MainActor.assumeIsolated { changed() } }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        var address = SystemOutput.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
}

/// The Mac's sound output while Your Devices is open, and whether there's anywhere else for
/// it to go. Both come from the system as they change.
///
/// Route detection keeps the Mac looking for AirPlay devices, so it runs only while someone's
/// looking, as the iPhone's ``SpeakerRouteObserver`` does.
@MainActor
@Observable
final class SystemOutputObserver {
    /// "MacBook Pro Speakers", "A Home's Pod". Nil until read.
    private(set) var name: String?
    /// What it is, nil for the Mac's own speakers.
    private(set) var speakers: NearbySpeakers?
    /// Somewhere besides the Mac to play to: an AirPlay speaker, a TV, headphones.
    private(set) var hasOtherRoutes = false

    @ObservationIgnored private let detector = AVRouteDetector()
    @ObservationIgnored private var follower: SystemOutputFollower?
    @ObservationIgnored private var observer: NSObjectProtocol?

    func start() {
        guard follower == nil else { return }
        follower = SystemOutputFollower { [weak self] in self?.readOutput() }
        observer = NotificationCenter.default.addObserver(forName: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readDetector() }
        }
        detector.isRouteDetectionEnabled = true
        readOutput()
        readDetector()
    }

    func stop() {
        follower?.stop()
        follower = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        detector.isRouteDetectionEnabled = false
    }

    private func readOutput() {
        let read = SystemOutput.read()
        if read?.name != name { name = read?.name }
        if read?.speakers != speakers { speakers = read?.speakers }
    }

    private func readDetector() {
        if detector.multipleRoutesDetected != hasOtherRoutes { hasOtherRoutes = detector.multipleRoutesDetected }
    }
}

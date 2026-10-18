import CoreAudio
import AVFoundation
import Accelerate
import Synchronization
import os

/// The Mac's own sound, as it goes out to the speakers, for the visualizer and the backgrounds
/// that move with the music. Apple Music plays where Tracks can't tap it, so without this
/// they'd replay each song's preview instead; with it they follow the song itself, beat for
/// beat, whatever's playing it.
///
/// It's a private Core Audio tap of everything the Mac plays, read through a private
/// aggregate device that nothing else sees. It runs only while something that moves with the
/// music is on screen. The first time, macOS asks whether Tracks may hear other apps' audio;
/// until it's allowed, or while nothing is playing, the tap hears silence, and ``isHearing``
/// says so, so the meter falls back to the preview. Nothing is recorded or kept: the last
/// few seconds sit in memory to be measured, and are written over.
nonisolated final class SystemAudioListener: @unchecked Sendable {
    static let shared = SystemAudioListener()

    let sound = HeardSound()
    /// When sound last came through, in host seconds.
    private let lastHeard = Atomic<UInt64>(0)
    private let queue = DispatchQueue(label: "Tracks.SystemAudioListener", qos: .userInteractive)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tracks", category: "SystemAudio")

    // Only touched on `queue`.
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var wanted = false
    private var outputListener: AudioObjectPropertyListenerBlock?

    private init() {}

    /// Starts hearing the Mac's sound, if it isn't already.
    func start() {
        queue.async { [self] in
            wanted = true
            guard proc == nil else { return }
            begin()
            watchOutput()
        }
    }

    /// Stops hearing it, and lets the tap go.
    func stop() {
        queue.async { [self] in
            wanted = false
            end()
        }
    }

    /// Whether sound has come through in the last moment: false while it's not allowed, or
    /// nothing's playing.
    var isHearing: Bool {
        let last = lastHeard.load(ordering: .relaxed)
        return last > 0 && Self.now() - Double(last) / 1e9 < 0.75
    }

    /// Now, in host seconds: the clock the tap's sound is timed by.
    static func now() -> Double {
        Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) / 1e9
    }

    // MARK: - The tap

    private func begin() {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Tracks Visualizer"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard check(AudioHardwareCreateProcessTap(description, &tap), "create the tap") else { return }
        self.tap = tap

        // The output device keeps the aggregate's clock, so the tap's sound arrives in step
        // with what's heard.
        var device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tracks Visualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if let output = Self.defaultOutputUID() {
            device[kAudioAggregateDeviceMainSubDeviceKey] = output
            device[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate), "create the device") else {
            end()
            return
        }
        self.aggregate = aggregate

        guard let format = Self.format(of: tap) else {
            log.error("Couldn't read the tap's format")
            end()
            return
        }
        sound.prepare(format)
        let sound = sound
        var proc: AudioDeviceIOProcID?
        let made = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [unowned self] _, input, inputTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = list.first, first.mDataByteSize > 0 else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * (list.count > 1 ? 1 : channels))
            let host = inputTime.pointee.mFlags.contains(.hostTimeValid)
                ? Double(AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime)) / 1e9
                : SystemAudioListener.now()
            // Silence, while it isn't allowed or nothing plays, doesn't count as hearing.
            if let data = first.mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                var loudest: Float = 0
                vDSP_maxmgv(samples, 4, &loudest, vDSP_Length((count + 3) / 4))
                if loudest > 1e-4 { self.lastHeard.store(UInt64(host * 1e9), ordering: .relaxed) }
            }
            sound.hear(UnsafeMutablePointer(mutating: input), frames: frames, at: CMTime(seconds: host, preferredTimescale: 1_000_000_000))
        }
        guard check(made, "listen to the device"), let proc else {
            end()
            return
        }
        self.proc = proc
        guard check(AudioDeviceStart(aggregate, proc), "start the device") else {
            end()
            return
        }
    }

    private func end() {
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
            self.proc = nil
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
            tap = AudioObjectID(kAudioObjectUnknown)
        }
        lastHeard.store(0, ordering: .relaxed)
    }

    /// Moved to other speakers, AirPods say, it starts again on them.
    private func watchOutput() {
        guard outputListener == nil else { return }
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, wanted else { return }
            end()
            begin()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            outputListener = listener
        }
    }

    private func check(_ status: OSStatus, _ what: String) -> Bool {
        if status != noErr { log.error("Couldn't \(what, privacy: .public): \(status)") }
        return status == noErr
    }

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func defaultOutputUID() -> String? {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func format(of tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}

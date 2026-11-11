#if os(macOS)
import Foundation
import Observation
import TracksCore
import TracksMusic

/// Music's speakers while Your Devices is open: read when it opens and every few seconds
/// after, as HomePods wake, sleep and change volume from elsewhere. Nothing is read while it's
/// closed.
@MainActor
@Observable
final class MusicSpeakersModel {
    /// Nil until read, and while Music is closed or Tracks may not control it.
    private(set) var speakers: MusicSpeakers?

    /// Volumes being dragged, sent no faster than Music takes them, latest first.
    @ObservationIgnored private var pendingVolumes: [String: Int] = [:]
    @ObservationIgnored private var sendingVolume = false
    /// While a change is on its way, a read could bring back the state from before it.
    @ObservationIgnored private var changedAt = Date.distantPast
    @ObservationIgnored private let isSample: Bool

    init() {
        #if DEBUG
        isSample = DemoMode.isRequestedAtLaunch && UserDefaults.standard.string(forKey: "TracksSpeakersDemo") != nil
        if isSample { speakers = Self.sample }
        #else
        isSample = false
        #endif
    }

    /// Reads now and then every three seconds, until the task is cancelled.
    func follow() async {
        guard !isSample else { return }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func refresh() async {
        let started = Date.now
        let reading = await ScriptingQueue.run { MusicAirPlay.read() }
        // A choice made while this was being read wins over what was read.
        guard started > changedAt else { return }
        switch reading {
        case .speakers(let read): if read != speakers { speakers = read }
        case .notRunning, .notAllowed: speakers = nil
        case .failed: break
        }
    }

    // MARK: - Choosing

    func chooseOnly(_ speaker: AirPlaySpeaker) {
        guard let speakers, !(speaker.isSelected && speakers.speakers.filter(\.isSelected).count == 1) else { return }
        self.speakers = speakers.choosingOnly(speaker.name)
        send { MusicAirPlay.choose(only: speaker.name) }
    }

    func toggle(_ speaker: AirPlaySpeaker) {
        guard let speakers else { return }
        let toggled = speakers.toggling(speaker.name)
        guard toggled != speakers else { return }
        self.speakers = toggled
        let selected = !speaker.isSelected
        send { MusicAirPlay.set(speaker.name, selected: selected) }
    }

    func setVolume(_ volume: Int, of speaker: AirPlaySpeaker) {
        guard let speakers else { return }
        self.speakers = speakers.setting(speaker.name, volume: volume)
        changedAt = .now
        guard !isSample else { return }
        pendingVolumes[speaker.name] = volume
        sendVolumes()
    }

    /// One volume at a time, the newest for each speaker, so a drag doesn't queue up dozens
    /// of Apple events behind it.
    private func sendVolumes() {
        guard !sendingVolume, let (name, volume) = pendingVolumes.first else { return }
        pendingVolumes[name] = nil
        sendingVolume = true
        Task {
            _ = await ScriptingQueue.run { MusicAirPlay.set(name, volume: volume) }
            changedAt = .now
            sendingVolume = false
            sendVolumes()
        }
    }

    private func send(_ change: @escaping @Sendable () -> Bool) {
        changedAt = .now
        guard !isSample else { return }
        Task {
            _ = await ScriptingQueue.run(change)
            changedAt = .now
            // Music settles a group a moment after it's asked.
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()
        }
    }

    #if DEBUG
    /// `-TracksSpeakersDemo YES` with demo data: a home's speakers, for screenshots.
    private static let sample = MusicSpeakers(state: .playing, speakers: [
        AirPlaySpeaker(name: "MacBook Pro", kind: .computer, isSelected: false, volume: 60),
        AirPlaySpeaker(name: "Kitchen", kind: .homePod, isSelected: true, volume: 45),
        AirPlaySpeaker(name: "Living Room", kind: .homePod, isSelected: true, volume: 30),
        AirPlaySpeaker(name: "Bedroom", kind: .homePod, isSelected: false, volume: 25),
        AirPlaySpeaker(name: "Living Room TV", kind: .appleTV, isSelected: false, volume: 50),
    ])
    #endif
}
#endif

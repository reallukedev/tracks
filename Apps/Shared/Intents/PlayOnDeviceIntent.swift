import AppIntents
import TracksCore
#if os(macOS)
import TracksMusic
#endif

/// "Play on my MacBook Pro in Tracks": moves what's playing here to another of your devices
/// nearby, from the same moment, as choosing it in Your Devices does. On the Mac a HomePod
/// or other AirPlay speaker can be chosen too, for what Music is playing, since Music is the
/// one player there an app can send to a speaker. iOS leaves that to the person, through
/// the system's picker, so the iPhone offers only your devices.
struct PlayOnDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Play on Another Device"
    #if os(macOS)
    static let description = IntentDescription(
        "Moves the song playing in Tracks to another of your devices nearby, from the same moment, or what Music is playing to a HomePod or another AirPlay speaker.",
        categoryName: "Your Devices"
    )
    #else
    static let description = IntentDescription(
        "Moves the song playing in Tracks to another of your devices nearby, from the same moment.",
        categoryName: "Your Devices"
    )
    #endif

    @Parameter(title: "Device")
    var device: NearbyDeviceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play on \(\.$device)")
    }

    init() {}

    init(device: NearbyDeviceEntity) {
        self.device = device
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { throw PlayIntentError.sampleData }
        #if os(macOS)
        if let speaker = device.speakerName {
            try await playOnSpeaker(speaker, model: model)
            return .result(dialog: "Playing on \(speaker).")
        }
        #endif
        guard let target = await model.nearby.waitForDevices(until: { $0.id == device.id }) else {
            throw PlayIntentError.problem(String(localized: "\(device.name) isn't nearby. Open Tracks on it, on the same Wi‑Fi."))
        }
        guard model.player.hasQueue else {
            throw PlayIntentError.problem(String(localized: "Nothing is playing in Tracks here to move."))
        }
        model.sendMusic(to: target)
        return .result(dialog: "Playing on \(target.name).")
    }

    #if os(macOS)
    /// Sends what Music is playing to one speaker alone, as choosing it in Your Devices does.
    /// Tracks' own player plays wherever the Mac's sound goes, which only the person chooses.
    @MainActor
    private func playOnSpeaker(_ name: String, model: AppModel) async throws {
        let presence = await ScriptingQueue.run { MusicScripting.presence() }
        if NearbyVoice.isTracks(hasSong: model.player.hasQueue, isPlaying: model.player.isPlaying, musicIsPlaying: presence.isPlaying) {
            throw PlayIntentError.problem(String(localized: "Choose \(name) with the AirPlay button in Tracks."))
        }
        guard presence.state == .playing || presence.state == .paused else {
            throw PlayIntentError.problem(String(localized: "Nothing is playing in Music to send to \(name)."))
        }
        guard await ScriptingQueue.run({ MusicAirPlay.choose(only: name) }) else {
            throw PlayIntentError.problem(String(localized: "Music couldn't play on \(name)."))
        }
    }
    #endif
}

/// "Bring the music here with Tracks": plays here what another of your devices is playing,
/// from the same moment, and pauses it there.
struct PlayHereIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Bring Music Here"
    static let description = IntentDescription(
        "Plays here the song another of your devices nearby is playing in Tracks, from the same moment, and pauses it there.",
        categoryName: "Your Devices"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        guard !model.isDemoLaunch else { throw PlayIntentError.sampleData }
        _ = await model.nearby.waitForDevices { $0.state?.hasSong == true }
        guard case .device(let id) = model.musicLocation,
              let device = model.nearby.devices.first(where: { $0.id == id })
        else {
            throw PlayIntentError.problem(String(localized: "None of your devices nearby is playing anything."))
        }
        guard await model.playHere(from: device) else {
            throw PlayIntentError.problem(String(localized: "The song playing on \(device.name) isn't available here."))
        }
        return .result()
    }
}

/// One of your devices nearby, for Siri and Shortcuts.
struct NearbyDeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Device"
    static let defaultQuery = NearbyDeviceQuery()

    let id: String
    let name: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    /// Music's speakers are known by name, the one way a script finds them again.
    static let speakerPrefix = "airplay:"

    /// The AirPlay speaker this is, rather than one of your devices.
    var speakerName: String? {
        id.hasPrefix(Self.speakerPrefix) ? String(id.dropFirst(Self.speakerPrefix.count)) : nil
    }
}

struct NearbyDeviceQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [NearbyDeviceEntity] {
        let found = await suggested()
        return identifiers.compactMap { id -> NearbyDeviceEntity? in
            if let entity = found.first(where: { $0.id == id }) { return entity }
            // A speaker in a shortcut made while Music was open still runs while it's closed.
            guard id.hasPrefix(NearbyDeviceEntity.speakerPrefix) else { return nil }
            let name = String(id.dropFirst(NearbyDeviceEntity.speakerPrefix.count))
            return NearbyDeviceEntity(id: id, name: name, symbol: "airplay.audio")
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [NearbyDeviceEntity] {
        await suggested()
    }

    /// Those here now, then every one known, so a shortcut made for a device that's away
    /// still finds it, then on the Mac Music's speakers.
    @MainActor
    private func suggested() async -> [NearbyDeviceEntity] {
        let nearby = AppModel.shared.nearby
        let here = nearby.devices.map { NearbyDeviceEntity(id: $0.id, name: $0.name, symbol: $0.kind.symbol) }
        let known = nearby.known
            .filter { device in !here.contains { $0.id == device.id } }
            .map { NearbyDeviceEntity(id: $0.id, name: $0.name, symbol: $0.deviceKind.symbol) }
        #if os(macOS)
        return here + known + (await speakers())
        #else
        return here + known
        #endif
    }

    #if os(macOS)
    /// Music's speakers besides the Mac, read only while Music is open, since asking a closed
    /// Music anything opens it.
    @MainActor
    private func speakers() async -> [NearbyDeviceEntity] {
        guard case .speakers(let read) = await ScriptingQueue.run({ MusicAirPlay.read() }) else { return [] }
        return read.speakers
            .filter { $0.kind != .computer }
            .map { NearbyDeviceEntity(id: NearbyDeviceEntity.speakerPrefix + $0.name, name: $0.name, symbol: $0.kind.symbol) }
    }
    #endif
}

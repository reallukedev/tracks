import AppIntents
import TracksCore

/// "Play on my MacBook Pro in Tracks": moves what's playing here to another of your devices
/// nearby, from the same moment, as choosing it in Your Devices does.
struct PlayOnDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "Play on Another Device"
    static let description = IntentDescription(
        "Moves the song playing in Tracks to another of your devices nearby, from the same moment.",
        categoryName: "Your Devices"
    )

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
        guard let target = await model.nearby.waitForDevices(until: { $0.id == device.id }) else {
            throw PlayIntentError.problem(String(localized: "\(device.name) isn't nearby. Open Tracks on it, on the same Wi‑Fi."))
        }
        guard model.player.hasQueue else {
            throw PlayIntentError.problem(String(localized: "Nothing is playing in Tracks here to move."))
        }
        model.sendMusic(to: target)
        return .result(dialog: "Playing on \(target.name).")
    }
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
}

struct NearbyDeviceQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [NearbyDeviceEntity] {
        suggested().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [NearbyDeviceEntity] {
        suggested()
    }

    /// Those here now, then every one known, so a shortcut made for a device that's away
    /// still finds it.
    @MainActor
    private func suggested() -> [NearbyDeviceEntity] {
        let nearby = AppModel.shared.nearby
        let here = nearby.devices.map { NearbyDeviceEntity(id: $0.id, name: $0.name, symbol: $0.kind.symbol) }
        let known = nearby.known
            .filter { device in !here.contains { $0.id == device.id } }
            .map { NearbyDeviceEntity(id: $0.id, name: $0.name, symbol: $0.deviceKind.symbol) }
        return here + known
    }
}

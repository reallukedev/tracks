import Foundation

/// A speaker Music can play to on the Mac, as its AirPlay menu lists them.
public nonisolated struct AirPlaySpeaker: Sendable, Hashable, Identifiable {
    public enum Kind: Int, Sendable, Comparable {
        // In the order Music's menu keeps them: the computer, then speakers, then screens.
        case computer, homePod, speaker, appleTV, tv, bluetooth

        /// Music's own name for the kind, `kind as text` in AppleScript.
        public init(musicKind: String) {
            switch musicKind.lowercased() {
            case "computer": self = .computer
            case "homepod": self = .homePod
            case "apple tv": self = .appleTV
            case "tv": self = .tv
            case "bluetooth device": self = .bluetooth
            default: self = .speaker
            }
        }

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The device's shape. The computer's is the Mac's own, which the app knows.
        public var symbol: String {
            switch self {
            case .computer: "laptopcomputer"
            case .homePod: "homepod.fill"
            case .speaker: "hifispeaker.fill"
            case .appleTV: "appletv.fill"
            case .tv: "tv"
            case .bluetooth: "headphones"
            }
        }

        public var isScreen: Bool { self == .appleTV || self == .tv }
    }

    /// Music's name for the device, which is also how a script finds it again.
    public let name: String
    public let kind: Kind
    public var isSelected: Bool
    /// 0 to 100, or nil when Music doesn't say.
    public var volume: Int?

    public var id: String { name }

    public init(name: String, kind: Kind, isSelected: Bool, volume: Int?) {
        self.name = name
        self.kind = kind
        self.isSelected = isSelected
        self.volume = volume.map { min(100, max(0, $0)) }
    }
}

/// Music's speakers and what it's doing, read in one Apple event.
public nonisolated struct MusicSpeakers: Sendable, Equatable {
    public var state: PlaybackState
    /// Available audio devices, in the order Music's menu lists them.
    public var speakers: [AirPlaySpeaker]

    public init(state: PlaybackState, speakers: [AirPlaySpeaker]) {
        self.state = state
        self.speakers = Self.ordered(speakers)
    }

    /// Whether there's anywhere to send the music besides the Mac itself.
    public var hasSpeakers: Bool { speakers.contains { $0.kind != .computer } }

    /// Whether any speaker listed is a screen, for the section's name.
    public var hasScreens: Bool { speakers.contains { $0.kind.isScreen } }

    /// Where the music is going, when it isn't only the Mac: "Kitchen", or each room in a
    /// group, the Mac included when it plays too. Nil while it plays on the Mac alone.
    public var destinationNames: [String]? {
        let selected = speakers.filter(\.isSelected)
        guard selected.contains(where: { $0.kind != .computer }) else { return nil }
        return selected.map(\.name)
    }

    /// Music's computer, then speakers, then screens, then Bluetooth, each by name, so a row
    /// stays where it is as it's chosen.
    public static func ordered(_ speakers: [AirPlaySpeaker]) -> [AirPlaySpeaker] {
        speakers.sorted {
            $0.kind != $1.kind ? $0.kind < $1.kind : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Reads what ``MusicAirPlay``'s script returns: a `state` line, then a `device` line for
    /// each device with its kind, available, supports audio, selected, volume and name, by tab.
    /// The name is last, so a tab in it stays part of it. Devices that are away or can't play
    /// audio are left out, and a name seen twice keeps its first line.
    public static func parse(_ output: String) -> MusicSpeakers {
        var state = PlaybackState.stopped
        var speakers: [AirPlaySpeaker] = []
        var names: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "state" where fields.count >= 2:
                state = PlaybackState(rawValue: fields[1].lowercased()) ?? .stopped
            case "device" where fields.count == 7:
                let name = fields[6].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, fields[2] == "true", fields[3] == "true", names.insert(name).inserted else { continue }
                speakers.append(AirPlaySpeaker(
                    name: name,
                    kind: AirPlaySpeaker.Kind(musicKind: fields[1]),
                    isSelected: fields[4] == "true",
                    volume: Int(fields[5])
                ))
            default:
                continue
            }
        }
        return MusicSpeakers(state: state, speakers: speakers)
    }

    /// The speakers after choosing one alone, as clicking its row does.
    public func choosingOnly(_ name: String) -> MusicSpeakers {
        guard speakers.contains(where: { $0.name == name }) else { return self }
        var copy = self
        for index in copy.speakers.indices {
            copy.speakers[index].isSelected = copy.speakers[index].name == name
        }
        return copy
    }

    /// The speakers after adding one to the group or taking it out. The last one playing
    /// can't be taken out: the music has to go somewhere.
    public func toggling(_ name: String) -> MusicSpeakers {
        guard let index = speakers.firstIndex(where: { $0.name == name }) else { return self }
        if speakers[index].isSelected, speakers.filter(\.isSelected).count == 1 { return self }
        var copy = self
        copy.speakers[index].isSelected.toggle()
        return copy
    }

    public func setting(_ name: String, volume: Int) -> MusicSpeakers {
        guard let index = speakers.firstIndex(where: { $0.name == name }) else { return self }
        var copy = self
        copy.speakers[index].volume = min(100, max(0, volume))
        return copy
    }
}

/// Where an iPhone's audio is going, from its audio session's outputs.
public nonisolated struct SpeakerRoute: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case airPlay, bluetooth, car, wired, screen
    }

    public let kind: Kind
    /// Each output's name: the rooms in an AirPlay group, or the headphones.
    public let names: [String]

    /// Nil while the phone plays through its own speaker. `outputs` are each port's type, as
    /// `AVAudioSession.Port`'s raw value, and name.
    public init?(outputs: [(type: String, name: String)]) {
        let kinds: [(Kind, String)] = outputs.compactMap { output in
            Self.kind(of: output.type).map { ($0, output.name.trimmingCharacters(in: .whitespaces)) }
        }
        // AirPlay leads: in a group with the phone, it's where the music is going.
        guard let kind = kinds.contains(where: { $0.0 == .airPlay }) ? .airPlay : kinds.first?.0 else { return nil }
        var seen: Set<String> = []
        let names = kinds.filter { $0.0 == kind && !$0.1.isEmpty && seen.insert($0.1).inserted }.map(\.1)
        guard !names.isEmpty else { return nil }
        self.kind = kind
        self.names = names
    }

    public init(kind: Kind, names: [String]) {
        self.kind = kind
        self.names = names
    }

    private static func kind(of port: String) -> Kind? {
        switch port {
        case "AirPlay": .airPlay
        case "BluetoothA2DPOutput", "BluetoothLE", "BluetoothHFP": .bluetooth
        case "CarAudio": .car
        case "Headphones", "LineOut", "USBAudio": .wired
        case "HDMI", "DisplayPort": .screen
        default: nil
        }
    }

    public var symbol: String {
        switch kind {
        case .airPlay: names.count > 1 ? "hifispeaker.2.fill" : "airplay.audio"
        case .bluetooth, .wired: "headphones"
        case .car: "car.fill"
        case .screen: "tv"
        }
    }
}

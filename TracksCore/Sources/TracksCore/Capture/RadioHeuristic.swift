import Foundation

/// Decides whether what Music.app is playing came from a radio station.
///
/// No API says so. Diffing a station against an album (see `docs/PlatformNotes.md`) showed that
/// a radio track reports no duration: `playerInfo` omits `Total Time` and AppleScript's
/// `duration of current track` is `missing value`. Music drops integer keys valued zero.
///
/// These were identical for radio and on demand, so they're no use: `cloud status`,
/// `current playlist`, `current stream title`/`URL`, `media kind`, and `database ID`.
public enum RadioHeuristic {
    /// What the platform reported, reduced to the fields that carry signal.
    public struct Evidence: Sendable, Equatable {
        /// Track length, if the platform gave one. Nil means radio.
        public let duration: TimeInterval?
        /// Present on demand and absent on radio in the sample. Corroboration only.
        public let hasComposer: Bool
        /// Advances on demand (28.1 → 29.2 → …) but stays at 0.0 on a station. Independent
        /// of the duration signal.
        public let playerPosition: TimeInterval?
        /// iOS only. The item half is `STREAM` for radio; when present it decides on its own.
        public let entryIdentifier: QueueEntryIdentifier?
        /// What the player said it was playing, when it knows. Tracks’ own player queued the
        /// music itself, so this decides on its own too, ahead of the entry identifier.
        public let statedStation: Bool?
        /// Whether the user has forced capture on, which overrides everything.
        public let userForcedCapture: Bool

        public init(
            duration: TimeInterval?,
            hasComposer: Bool = false,
            playerPosition: TimeInterval? = nil,
            entryIdentifier: QueueEntryIdentifier? = nil,
            statedStation: Bool? = nil,
            userForcedCapture: Bool = false
        ) {
            self.duration = duration
            self.hasComposer = hasComposer
            self.playerPosition = playerPosition
            self.entryIdentifier = entryIdentifier
            self.statedStation = statedStation
            self.userForcedCapture = userForcedCapture
        }
    }

    public enum Verdict: Sendable, Equatable {
        case radio(confidence: Confidence)
        case onDemand
        /// Not enough to go on. Capture nothing, since a wrong capture puts the wrong song
        /// in someone's library.
        case unknown

        public var shouldCapture: Bool {
            if case .radio = self { return true }
            return false
        }
    }

    public enum Confidence: Sendable, Equatable, Comparable {
        case likely        // one inferred signal
        case corroborated  // both inferred signals agree
        case stated        // the queue entry says STREAM outright (iOS)
        case asserted      // the user said so
    }

    public static func evaluate(_ evidence: Evidence) -> Verdict {
        // The user's toggle beats any inference.
        if evidence.userForcedCapture { return .radio(confidence: .asserted) }

        // Tracks started this music, so it knows. No inference can beat that.
        if let statedStation = evidence.statedStation {
            return statedStation ? .radio(confidence: .stated) : .onDemand
        }

        // Ignore the macOS signals on iOS: MusicKit reports a real Song.duration for a radio
        // track once the entry resolves.
        if let identifier = evidence.entryIdentifier {
            return identifier.isStream ? .radio(confidence: .stated) : .onDemand
        }

        // Zero or negative also means no known length.
        let reportsNoDuration = (evidence.duration ?? 0) <= 0
        let positionPinnedAtZero = evidence.playerPosition.map { $0 <= 0 }

        guard reportsNoDuration else { return .onDemand }

        // Duration alone is enough to capture; position and composer only raise confidence.
        let corroborated = positionPinnedAtZero == true && !evidence.hasComposer
        return .radio(confidence: corroborated ? .corroborated : .likely)
    }
}

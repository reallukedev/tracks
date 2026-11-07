import Foundation

/// What to do about one observation, decided before anything is written or awaited.
///
/// Kept apart from the store so the policy can be tested on its own. Every rejection
/// carries a reason, so "nothing was captured" can be traced.
public enum CaptureDecision: Sendable, Equatable {
    case capture(Capturable)
    case ignore(Reason)

    public struct Capturable: Sendable, Equatable {
        public let observation: NowPlayingObservation
        /// `.radio` or `.onDemand`. Only radio goes to the playlist and play-back.
        public let kind: CaptureKind
        public let confidence: RadioHeuristic.Confidence
        /// Set when the platform gave an ID; nil means a catalog search is needed.
        public let catalogSongID: String?
        /// Present when this observation also names the station.
        public let stationName: String?

        public init(
            observation: NowPlayingObservation,
            kind: CaptureKind = .radio,
            confidence: RadioHeuristic.Confidence,
            catalogSongID: String?,
            stationName: String?
        ) {
            self.observation = observation
            self.kind = kind
            self.confidence = confidence
            self.catalogSongID = catalogSongID
            self.stationName = stationName
        }
    }

    public enum Reason: Sendable, Equatable {
        /// Paused, stopped, or an empty state-change payload.
        case notPlaying
        /// The queue announced a station, not a track.
        case stationAnnouncement(name: String)
        /// Playing on demand, with on-demand capture switched off.
        case onDemand
        /// Not enough metadata to identify anything.
        case unidentifiable
        /// The user excluded this station in Settings.
        case excludedStation(name: String)
        /// Seen recently enough to be the same play. Common, since macOS polls every 10 seconds.
        case duplicate(secondsSinceLast: TimeInterval)
        /// Playing, but not long enough to count yet. The caller uses `needs` to know when
        /// to check again.
        case tooShort(playedFor: TimeInterval, needs: TimeInterval)
    }

    public var isCapture: Bool {
        if case .capture = self { return true }
        return false
    }
}

/// Decides what happens to an observation. Pure, synchronous, and total.
public struct CapturePolicy: Sendable {
    public let dedupe: DedupePolicy
    public let excludedStations: Set<String>
    public let forceCapture: Bool
    /// Whether to keep on-demand plays too. Off, only stations are recorded.
    public let capturesOnDemand: Bool

    public init(
        dedupe: DedupePolicy = .default,
        excludedStations: Set<String> = [],
        forceCapture: Bool = false,
        capturesOnDemand: Bool = true
    ) {
        self.dedupe = dedupe
        self.excludedStations = excludedStations
        self.forceCapture = forceCapture
        self.capturesOnDemand = capturesOnDemand
    }

    /// - Parameter lastSeen: when this song was last captured, if ever. Read in the same
    ///   synchronous transaction as the insert, so two observations can't both pass.
    public func decide(
        _ observation: NowPlayingObservation,
        lastSeen: Date?,
        now: Date = .now
    ) -> CaptureDecision {
        guard observation.playbackState == .playing else { return .ignore(.notPlaying) }

        if let station = observation.announcedStationName {
            return .ignore(.stationAnnouncement(name: station))
        }

        guard observation.isIdentifiable else { return .ignore(.unidentifiable) }

        let verdict = observation.radioVerdict(userForcedCapture: forceCapture)
        let kind: CaptureKind
        let confidence: RadioHeuristic.Confidence
        switch verdict {
        case .radio(let stated):
            kind = .radio
            confidence = stated
        case .onDemand:
            guard capturesOnDemand else { return .ignore(.onDemand) }
            kind = .onDemand
            // Confidence is about radio, so it means nothing here. It's only logged.
            confidence = .likely
        case .unknown:
            // `RadioHeuristic.evaluate` never returns this today. Don't keep what we can't
            // classify.
            return .ignore(.unidentifiable)
        }

        // Only stations can be excluded.
        if kind == .radio, let station = observation.stationName,
           excludedStations.contains(station) {
            return .ignore(.excludedStation(name: station))
        }

        guard dedupe.shouldCapture(lastSeen: lastSeen, now: now) else {
            let elapsed = lastSeen.map { now.timeIntervalSince($0) } ?? 0
            return .ignore(.duplicate(secondsSinceLast: elapsed))
        }

        return .capture(
            .init(
                observation: observation,
                kind: kind,
                confidence: confidence,
                catalogSongID: observation.catalogSongID,
                stationName: observation.stationName
            )
        )
    }
}

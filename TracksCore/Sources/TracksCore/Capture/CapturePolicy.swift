import Foundation

/// When two observations of the same song count as one capture.
public struct DedupePolicy: Sendable, Equatable {
    /// The same catalog song ID seen again inside this window is the same play.
    /// Configurable in Settings.
    public var window: TimeInterval

    /// How long after a witnessed play an import of the same song is still that play.
    ///
    /// An import is dated when it was *found*, not when it played (see ``HistoryImport``), so
    /// it lands after the witnessed copy, once observed 45 minutes after it. The ordinary
    /// window is far too short to catch that.
    ///
    /// It must still be bounded. Treating an import as "always the same play" meant a song
    /// played again a month later was merged into the first play and deleted.
    public var importWindow: TimeInterval

    public init(window: TimeInterval = 10 * 60, importWindow: TimeInterval = 24 * 60 * 60) {
        self.window = window
        self.importWindow = importWindow
    }

    public static let `default` = DedupePolicy()

    /// How far apart two rows of the same song can be and still be one play.
    ///
    /// Directional, and `earlier` must be the earlier of the two. What decides it is whether
    /// the *later* row is an import, because that is the row whose timestamp is in question:
    /// an import is dated when it was found, which is always at or after the play itself, so
    /// it can be pulled back to an earlier row of the same song. A witnessed row is dated
    /// when it was seen, so it only ever merges inside the ordinary window.
    ///
    /// That covers two separate ways one play becomes two rows:
    ///
    /// - A play this device witnessed, then recovered from Recently Played before the
    ///   witnessed row ruled it out, once seen 45 minutes apart.
    /// - A play on *another* device. Apple Music's recently-played list is account-wide, so
    ///   the iPhone reads back plays that happened on the Mac and imports them dated now,
    ///   hours later. ``TracksStore/importPlayedSongs(_:lookback:settings:now:)`` suppresses
    ///   that when the other device's row has already synced, and this catches it when it
    ///   hasn't.
    ///
    /// A day is the horizon because the importer uses the same one: it will not write a
    /// second import of a song already in the store from the last 24 hours. So two imports
    /// closer together than that cannot have come from one device, and are the same play seen
    /// twice, while two further apart are two plays the importer deliberately let through.
    public func mergeWindow(earlier: CaptureKind, later: CaptureKind) -> TimeInterval {
        later.timeIsKnown ? window : importWindow
    }

    /// Whether a new observation should be recorded, given when this song was last seen.
    ///
    /// Synchronous because the store calls it inside its write transaction, before any
    /// `await`, so two quick observations of one song can't both pass.
    public func shouldCapture(lastSeen: Date?, now: Date) -> Bool {
        guard let lastSeen else { return true }
        return now.timeIntervalSince(lastSeen) >= window
    }
}

/// When a listening session starts and ends.
public struct SessionPolicy: Sendable, Equatable {
    /// A session closes after this much quiet.
    public var silenceTimeout: TimeInterval

    public init(silenceTimeout: TimeInterval = 15 * 60) {
        self.silenceTimeout = silenceTimeout
    }

    public static let `default` = SessionPolicy()

    public enum Decision: Sendable, Equatable {
        /// Keep appending to the open session.
        case current
        /// Close the open session and start a new one.
        case startNew
    }

    /// Whether an observation belongs to the open session or begins a new one.
    ///
    /// A station change always starts a new session, even with no gap.
    public func decide(
        openSessionStation: String?,
        openSessionLastActivity: Date?,
        observedStation: String?,
        now: Date
    ) -> Decision {
        guard let lastActivity = openSessionLastActivity else { return .startNew }
        if now.timeIntervalSince(lastActivity) >= silenceTimeout { return .startNew }
        // An unknown station counts as the same one, so a missing name doesn't split the session.
        guard let observedStation else { return .current }
        guard let openSessionStation else { return .current }
        // Folded, as the store matches stations, so a stray space or a change of case in
        // the name Apple reports doesn't split one listen in two.
        return StatsCalculator.folded(observedStation) == StatsCalculator.folded(openSessionStation)
            ? .current : .startNew
    }
}

/// When a play is worth reporting to a scrobbling service.
///
/// Last.fm's rule, which also satisfies ListenBrainz: the track is longer than 30 seconds
/// and was played for half its length or 4 minutes, whichever comes first.
public struct ScrobblePolicy: Sendable, Equatable {
    public static let minimumTrackDuration: TimeInterval = 30
    public static let maximumRequiredPlayback: TimeInterval = 240

    public init() {}

    /// Whether a track of `duration`, played for `playedFor`, qualifies.
    public func shouldScrobble(duration: TimeInterval, playedFor: TimeInterval) -> Bool {
        guard let threshold = requiredPlayback(forDuration: duration) else { return false }
        return playedFor >= threshold
    }

    /// How long a track of `duration` has to play to qualify. Nil for one too short to ever
    /// qualify. A track of unknown length is taken as ``CaptureSettings/assumedSongLength``,
    /// as the share that must play before a song counts is.
    public func requiredPlayback(forDuration duration: TimeInterval?) -> TimeInterval? {
        let length = duration.flatMap { $0 > 0 ? $0 : nil } ?? CaptureSettings.assumedSongLength
        guard length > Self.minimumTrackDuration else { return nil }
        return min(length / 2, Self.maximumRequiredPlayback)
    }

    /// Why a play isn't owed to Last.fm, kept on the row in ``Capture/lastScrobbleError``.
    /// Also how a row held back by this policy is told from one Last.fm refused.
    public static let tooShortReason = "Last.fm doesn’t count tracks of 30 seconds or less."
    public static let notPlayedEnoughReason = "Last.fm counts a song once half of it or four minutes has played."
}

extension Capture {
    /// Whether the scrobble queue is passing this play over because it's too short or didn't
    /// play long enough for Last.fm, rather than because Last.fm refused it.
    public var isHeldFromScrobbling: Bool {
        scrobbledAt == nil
            && (lastScrobbleError == ScrobblePolicy.tooShortReason
                || lastScrobbleError == ScrobblePolicy.notPlayedEnoughReason)
    }

    /// Keeps the play out of the scrobble queue, which skips rows that have used up their
    /// attempts. No new field, which CloudKit would need deploying again for.
    @MainActor
    func holdFromScrobbling(reason: String) {
        scrobbleAttempts = TracksStore.maxScrobbleAttempts
        lastScrobbleError = reason
    }

    /// Puts a play held back by ``holdFromScrobbling(reason:)`` into the scrobble queue.
    func releaseForScrobbling() {
        guard isHeldFromScrobbling else { return }
        scrobbleAttempts = 0
        lastScrobbleError = nil
    }
}

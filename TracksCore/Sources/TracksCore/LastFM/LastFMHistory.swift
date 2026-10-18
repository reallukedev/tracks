import Foundation

/// One scrobble read back from Last.fm.
public struct ScrobbledTrack: Sendable, Equatable {
    public let title: String
    public let artistName: String
    public let albumTitle: String?
    public let artworkURL: String?
    public let playedAt: Date

    public init(
        title: String,
        artistName: String,
        albumTitle: String? = nil,
        artworkURL: String? = nil,
        playedAt: Date
    ) {
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.artworkURL = artworkURL
        self.playedAt = playedAt
    }
}

/// One page of `user.getRecentTracks`, newest first.
public struct ScrobbleHistoryPage: Sendable, Equatable {
    public let scrobbles: [ScrobbledTrack]
    /// Scrobbles in the whole range asked for, not just this page.
    public let total: Int
    public let totalPages: Int
}

/// Bringing the connected account's Last.fm history into Tracks.
///
/// Unlike an import from Recently Played, every scrobble says when it played, so rows are
/// dated then (``CaptureKind/lastFM``). They are already on Last.fm, so they are never sent
/// back, and a play Tracks has already kept, which it will usually have scrobbled itself, is
/// skipped rather than written twice.
public enum LastFMHistory {

    /// A row already in the store, as the duplicate check sees it.
    public struct KnownPlay: Sendable, Equatable {
        public let key: String
        public let playedAt: Date
        public let kind: CaptureKind

        public init(key: String, playedAt: Date, kind: CaptureKind) {
            self.key = key
            self.playedAt = playedAt
            self.kind = kind
        }
    }

    /// The scrobbles worth writing, oldest first.
    ///
    /// A scrobble is the same play as a row of the same song close enough to it, by the
    /// windows ``TracksStore/mergeDuplicateCaptures(policy:)`` merges with. Anything it would
    /// merge is left out here, so an import never writes a row the next merge deletes. That
    /// covers Tracks’ own scrobbles (dated exactly as the row), another app's scrobble of a
    /// play Tracks also kept, and an import from Recently Played found hours after the play.
    /// Scrobbles already accepted count too, so one song scrobbled twice within the window is
    /// kept once.
    public static func newPlays(
        in scrobbles: [ScrobbledTrack],
        known: [KnownPlay],
        forgotten: Set<String>,
        policy: DedupePolicy
    ) -> [ScrobbledTrack] {
        var plays: [String: [(at: Date, kind: CaptureKind)]] = [:]
        for play in known { plays[play.key, default: []].append((play.playedAt, play.kind)) }

        var result: [ScrobbledTrack] = []
        for scrobble in scrobbles.sorted(by: { $0.playedAt < $1.playedAt }) {
            let key = HistoryImport.key(title: scrobble.title, artistName: scrobble.artistName)
            guard !forgotten.contains(key) else { continue }
            let isKnown = plays[key, default: []].contains { other in
                if other.at <= scrobble.playedAt {
                    let window = policy.mergeWindow(earlier: other.kind, later: .lastFM)
                    return scrobble.playedAt.timeIntervalSince(other.at) < window
                }
                let window = policy.mergeWindow(earlier: .lastFM, later: other.kind)
                return other.at.timeIntervalSince(scrobble.playedAt) < window
            }
            guard !isKnown else { continue }
            plays[key, default: []].append((scrobble.playedAt, .lastFM))
            result.append(scrobble)
        }
        return result
    }

    /// How far an import has got, kept between runs so one that stops part way picks up
    /// where it left off, and a later sync only reads what's new.
    ///
    /// Last.fm lists newest first, so a run reads down from the top. Everything up to
    /// ``importedThrough`` is in; a run that hasn't finished has read everything from
    /// ``runNewest`` down to ``runBefore``, and the gap between that and ``importedThrough``
    /// is what's left.
    public struct Progress: Codable, Sendable, Equatable {
        /// The account this is about. Another account starts from nothing.
        public var username: String
        /// Every scrobble at or before this is in Tracks. Nil until a first import finishes.
        public var importedThrough: Date?
        /// The newest scrobble of an unfinished run.
        public var runNewest: Date?
        /// The oldest scrobble an unfinished run has reached.
        public var runBefore: Date?
        /// When the last run finished.
        public var lastFinished: Date?
        /// How many plays imports have added in all, for Settings.
        public var imported: Int

        public init(username: String) {
            self.username = username
            imported = 0
        }

        /// Whether a run stopped part way through.
        public var isUnfinished: Bool { runBefore != nil }
    }
}

/// Reads the connected account's scrobbles into the store, a page at a time.
@MainActor
public final class LastFMHistoryImporter {
    /// What a run has done so far.
    public struct Report: Sendable, Equatable {
        /// Scrobbles read from Last.fm.
        public var read = 0
        /// How many of those were new to Tracks.
        public var imported = 0
        /// Scrobbles in the range being read, once the first page says.
        public var total: Int?

        public init(read: Int = 0, imported: Int = 0, total: Int? = nil) {
            self.read = read
            self.imported = imported
            self.total = total
        }
    }

    private let client: LastFMClient
    private let session: LastFMSession
    private let store: TracksStore
    private let settings: CaptureSettings
    /// Waits between retries of a request Last.fm said to try again, replaceable in tests.
    var pause: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var now: () -> Date = { .now }

    /// How many times one page is tried when Last.fm is busy or the network drops.
    static let attempts = 4

    public init(client: LastFMClient, session: LastFMSession, store: TracksStore, settings: CaptureSettings = CaptureSettings()) {
        self.client = client
        self.session = session
        self.store = store
        self.settings = settings
    }

    /// Reads every scrobble Tracks doesn't have yet.
    ///
    /// The first run reads the whole history; later ones only what's newer than the last.
    /// Progress is saved after every page, so cancelling or failing loses at most one page.
    ///
    /// - Parameter update: called after each page.
    @discardableResult
    public func run(update: (Report) -> Void = { _ in }) async throws -> Report {
        var progress = settings.lastFMHistory(for: session.username)
        var report = Report()

        // An unfinished run is finished first, then a fresh one picks up what was scrobbled
        // since it started.
        let resumes = progress.isUnfinished
        try await walk(&progress, report: &report, update: update)
        if resumes { try await walk(&progress, report: &report, update: update) }
        progress.lastFinished = now()
        settings.lastFMHistoryProgress = progress
        update(report)
        return report
    }

    /// Reads from the top of the range down to ``LastFMHistory/Progress/importedThrough``.
    private func walk(
        _ progress: inout LastFMHistory.Progress,
        report: inout Report,
        update: (Report) -> Void
    ) async throws {
        let after = progress.importedThrough
        // The first page of a fresh run is read up to now, so pages further down don't move
        // as new scrobbles arrive.
        var before = progress.runBefore ?? now()
        var isFirstPage = true

        while true {
            try Task.checkCancellation()
            let page = try await fetch(after: after, before: before)
            if isFirstPage {
                report.total = report.read + page.total
                isFirstPage = false
            }
            guard let oldest = page.scrobbles.map(\.playedAt).min(),
                  let newest = page.scrobbles.map(\.playedAt).max()
            else { break }

            let added = try store.importScrobbles(page.scrobbles, settings: settings)
            report.imported += added
            report.read += page.scrobbles.count

            // Last.fm's range includes its ends, so the next page starts at this one's oldest
            // and reads it again; the duplicate check skips it. A page all in one second would
            // otherwise be read forever.
            before = oldest < before ? oldest : before.addingTimeInterval(-1)
            progress.runNewest = max(progress.runNewest ?? newest, newest)
            progress.runBefore = before
            progress.imported += added
            settings.lastFMHistoryProgress = progress
            update(report)

            if page.totalPages <= 1 { break }
        }

        if let newest = progress.runNewest {
            progress.importedThrough = max(progress.importedThrough ?? newest, newest)
        }
        progress.runNewest = nil
        progress.runBefore = nil
        settings.lastFMHistoryProgress = progress
    }

    /// One page, tried again when Last.fm says it's busy or the connection drops.
    private func fetch(after: Date?, before: Date) async throws -> ScrobbleHistoryPage {
        var attempt = 1
        while true {
            do {
                return try await client.recentTracks(session: session, after: after, before: before)
            } catch let error where attempt < Self.attempts && Self.isWorthRetrying(error) {
                try await pause(.seconds(1 << attempt))
                attempt += 1
            }
        }
    }

    static func isWorthRetrying(_ error: any Error) -> Bool {
        if let error = error as? LastFMError { return error.isRetryable }
        return error is URLError
    }
}

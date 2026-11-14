import Foundation
import OSLog
import Synchronization
import TracksEngine

/// The play history as the shared Rust engine indexes it: charts and totals read from a
/// SQLite index with running totals, instead of a pass over every play held in memory.
///
/// The index mirrors the store and is never the source of truth. It can be deleted at any
/// time and fills itself again from the history, so anything that goes wrong with it costs a
/// rebuild, never a play. Every call is synchronous and does real work: call it off the main
/// actor.
public final class HistoryEngine: Sendable {
    private let index: HistoryIndex
    /// Whether the index matches the history: true once a full sync lands, false again after
    /// any write fails, until the next full sync. Charts only answer while it's true, so a
    /// missed change can never show as a wrong number; the Swift calculator stands in.
    private let isCurrent = Mutex(false)

    /// Thrown by the charts while the index may be behind the history.
    public struct NotCurrent: Error {}
    private static let log = Logger(subsystem: "com.luke.tracks", category: "HistoryEngine")

    private init(index: HistoryIndex) {
        self.index = index
        try? index.setTimeZone(identifier: TimeZone.current.identifier)
    }

    /// Opens the engine the first time it's asked for, on whichever thread asks, so opening
    /// the file never lands on the main actor at launch.
    public final class Source: Sendable {
        private let state: Mutex<HistoryEngine??> = Mutex(nil)
        private let open: @Sendable () -> HistoryEngine?

        public init(_ open: @escaping @Sendable () -> HistoryEngine?) {
            self.open = open
        }

        /// The engine, opening it if this is the first ask. Nil if it couldn't be opened.
        /// Call off the main actor.
        public var engine: HistoryEngine? {
            state.withLock { state in
                if let opened = state { return opened }
                let opened = open()
                state = .some(opened)
                return opened
            }
        }
    }

    /// The index for the app's own history, beside the store in the App Group container, so
    /// the widgets can read it too. Nil if it can't be opened, and callers carry on without it.
    public static func shared() -> HistoryEngine? {
        let folder = (AppGroup.containerURL ?? URL.applicationSupportDirectory)
            .appending(path: "Library/Application Support/Tracks", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return HistoryEngine(index: try HistoryIndex.open(path: folder.appending(path: "history-index.sqlite").path(percentEncoded: false)))
        } catch {
            log.error("Couldn't open the history index: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// An index that lives in memory, for sample data, previews and tests, which must never
    /// write the real one.
    public static func inMemory() -> HistoryEngine? {
        try? HistoryEngine(index: HistoryIndex.inMemory())
    }

    // MARK: - Keeping up with the store

    /// Brings the index up to date with a change the store's reader reported. Errors are
    /// logged rather than thrown: a stale index only means the charts fall back to Swift.
    public func apply(_ change: ListeningHistoryReader.Change) {
        do {
            try index.setTimeZone(identifier: TimeZone.current.identifier)
            switch change {
            case .everything(let snapshot):
                let report = try index.sync(plays: snapshot.captures.map(Self.play), marker: nil)
                isCurrent.withLock { $0 = true }
                Self.log.info("Synced the history index: \(report.inserted) added, \(report.updated) changed, \(report.removed) removed")
            case .steps(let steps, _):
                for step in steps {
                    // A play whose key moved (its song was renamed) goes, and comes back new.
                    let moved = step.changed.compactMap { Self.key($0.old) == Self.key($0.new) ? nil : Self.key($0.old) }
                    if !moved.isEmpty { _ = try index.remove(ids: moved, marker: nil) }
                    let plays = step.added.map(Self.play) + step.changed.map { Self.play($0.new) }
                    if !plays.isEmpty { _ = try index.upsert(plays: plays, marker: nil) }
                }
            }
        } catch {
            isCurrent.withLock { $0 = false }
            Self.log.error("Couldn't update the history index: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Brings the index to exactly these plays: the whole history.
    public func sync(_ captures: [CaptureStat]) {
        apply(.everything(.init(captures: captures, sessions: [])))
    }

    /// The reader has no stable id for a play that would survive a relaunch, so a play is
    /// known by when it was heard, how, and what. Two copies of the same play from two devices
    /// count once, as they will once the store merges them.
    private static func key(_ capture: CaptureStat) -> String {
        "\(milliseconds(capture.capturedAt))\u{1F}\(capture.kind.rawValue)\u{1F}\(capture.source.rawValue)\u{1F}\(capture.songIdentity)"
    }

    private static func play(_ capture: CaptureStat) -> Play {
        Play(
            id: key(capture),
            catalogId: capture.songID,
            songKey: capture.songKey,
            title: capture.title,
            artistName: capture.artistName,
            albumTitle: capture.albumTitle,
            artworkUrl: capture.artworkURL,
            playedAtMs: milliseconds(capture.capturedAt),
            kind: kind(capture.kind),
            source: capture.source == .yourMusic ? .yourMusic : .appleMusic,
            stationName: capture.stationName
        )
    }

    private static func kind(_ kind: CaptureKind) -> TracksEngine.PlayKind {
        switch kind {
        case .radio: .radio
        case .onDemand: .onDemand
        case .imported: .imported
        case .lastFM: .lastFm
        }
    }

    // MARK: - Charts

    /// The songs of a period, ranked, with movement against the period before. The same
    /// chart ``StatsCalculator/songChart(in:history:calendar:limit:)`` gives.
    public func songChart(in period: ChartPeriod, scope: SourceScope, calendar: Calendar = .current, limit: Int = 100) throws -> [Ranked<SongTally>] {
        try ensureCurrent()
        let chart = try index.songChart(period: Self.period(period), previous: Self.previous(period, calendar: calendar), filter: Self.filter(scope), limit: Self.limit(limit))
        return chart.rows.map { row in
            Ranked(item: Self.tally(row.song), rank: Int(row.rank), previousRank: row.previousRank.map(Int.init), hasPrevious: chart.hasPrevious)
        }
    }

    /// The artists of a period, ranked. A play counts in full for everyone it credits.
    public func artistChart(in period: ChartPeriod, scope: SourceScope, calendar: Calendar = .current, limit: Int = 100) throws -> [Ranked<ArtistTally>] {
        try ensureCurrent()
        let chart = try index.artistChart(period: Self.period(period), previous: Self.previous(period, calendar: calendar), filter: Self.filter(scope), limit: Self.limit(limit))
        return chart.rows.map { row in
            let artist = row.artist
            return Ranked(
                item: ArtistTally(
                    id: artist.identity,
                    name: artist.name,
                    count: Int(artist.plays),
                    songCount: Int(artist.songCount),
                    listeningSeconds: Self.seconds(artist.listenMs),
                    artworkURL: artist.artworkUrl,
                    firstHeard: Self.date(artist.firstPlayedMs),
                    lastHeard: Self.date(artist.lastPlayedMs)
                ),
                rank: Int(row.rank),
                previousRank: row.previousRank.map(Int.init),
                hasPrevious: chart.hasPrevious
            )
        }
    }

    /// The albums of a period, ranked.
    public func albumChart(in period: ChartPeriod, scope: SourceScope, calendar: Calendar = .current, limit: Int = 100) throws -> [Ranked<AlbumTally>] {
        try ensureCurrent()
        let chart = try index.albumChart(period: Self.period(period), previous: Self.previous(period, calendar: calendar), filter: Self.filter(scope), limit: Self.limit(limit))
        return chart.rows.map { row in
            let album = row.album
            return Ranked(
                item: AlbumTally(
                    id: album.identity,
                    title: album.title,
                    artistName: album.artistName,
                    count: Int(album.plays),
                    songCount: Int(album.songCount),
                    artworkURL: album.artworkUrl,
                    listeningSeconds: Self.seconds(album.listenMs)
                ),
                rank: Int(row.rank),
                previousRank: row.previousRank.map(Int.init),
                hasPrevious: chart.hasPrevious
            )
        }
    }

    private func ensureCurrent() throws {
        guard isCurrent.withLock({ $0 }) else { throw NotCurrent() }
    }

    /// How many plays the index holds, to check it caught up with the store.
    public func playCount() throws -> Int {
        Int(try index.playCount())
    }

    /// Checkpoints and tidies the file, for when the app goes to the background.
    public func optimize() {
        try? index.optimize()
    }

    // MARK: - Conversions

    private static func tally(_ song: SongStats) -> SongTally {
        SongTally(
            id: song.identity,
            songKey: song.songKey,
            songID: song.catalogId,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            artworkURL: song.artworkUrl,
            count: Int(song.plays),
            firstHeard: date(song.firstPlayedMs),
            lastHeard: date(song.lastPlayedMs),
            listeningSeconds: seconds(song.listenMs)
        )
    }

    private static func period(_ period: ChartPeriod) -> TracksEngine.Period {
        guard let interval = period.interval else { return TracksEngine.Period(startMs: nil, endMs: nil) }
        return TracksEngine.Period(startMs: milliseconds(interval.start), endMs: milliseconds(interval.end))
    }

    private static func previous(_ period: ChartPeriod, calendar: Calendar) -> TracksEngine.Period? {
        period.previous(calendar: calendar).map(Self.period)
    }

    private static func filter(_ scope: SourceScope) -> SourceFilter {
        switch scope {
        case .all: .all
        case .appleMusic: .appleMusic
        case .yourMusic: .yourMusic
        }
    }

    private static func limit(_ limit: Int) -> UInt32 {
        UInt32(clamping: max(0, limit))
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    private static func seconds(_ milliseconds: Int64) -> TimeInterval {
        TimeInterval(milliseconds) / 1000
    }
}

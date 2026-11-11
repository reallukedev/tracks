import Foundation
import SwiftData

/// The listening history as plain values, read off the main actor and kept up to date from
/// the store's own record of what changed.
///
/// Reading every capture has a floor: SwiftData takes a couple of seconds to materialise a
/// hundred and fifty thousand rows, however the fetch is tuned. The app used to do that on
/// the main actor after every save, so a large library froze for seconds after each song.
/// This reads everything once, then asks the store's history which captures and sessions
/// were inserted, changed or deleted since, and fetches only those. Rows synced in from
/// another device are in that history too.
///
/// Each read makes its own `ModelContext` and lets it go before returning, so no context
/// outlives a call or crosses to another thread.
public actor ListeningHistoryReader {

    /// Every play and session, in no particular order.
    public struct Snapshot: Sendable {
        public let captures: [CaptureStat]
        public let sessions: [SessionStat]
    }

    private struct SessionRow {
        var stat: SessionStat
        var captureIDs: Set<PersistentIdentifier>
    }

    /// Past this many changed rows, one full read is cheaper than fetching them by identifier.
    static let incrementalLimit = 5_000
    /// How many identifiers go into one `contains` predicate.
    private static let fetchChunk = 1_000

    private let container: ModelContainer
    private var captures: [PersistentIdentifier: CaptureStat] = [:]
    private var sessionOfCapture: [PersistentIdentifier: PersistentIdentifier] = [:]
    private var sessions: [PersistentIdentifier: SessionRow] = [:]
    /// The last transaction folded in. Nil before the first read, or when the store has no
    /// history at all yet.
    private var token: DefaultHistoryToken?
    private var hasRead = false
    /// Set if the store can't report its history, so every read is a full one.
    private var historyUnavailable = false

    /// How the last read was done, for tests and the probe.
    public enum ReadKind: Sendable, Equatable {
        case full, incremental, unchanged
    }
    public private(set) var lastRead: ReadKind?

    /// Goes up whenever what the reader holds changes, so each of several callers can tell
    /// whether there's anything new for it.
    public private(set) var version = 0
    /// The version ``read()`` last handed out.
    private var versionRead: Int?

    public init(container: ModelContainer) {
        self.container = container
    }

    /// The history as it is now, or nil if nothing has changed since the last call.
    ///
    /// For a single caller. With several, each keeps its own version and uses
    /// ``snapshot(after:)``.
    public func read() throws -> Snapshot? {
        guard let (snapshot, version) = try snapshot(after: versionRead) else { return nil }
        versionRead = version
        return snapshot
    }

    /// The history as it is now, with the version it's at, or nil if it's still at `version`.
    public func snapshot(after version: Int?) throws -> (snapshot: Snapshot, version: Int)? {
        try update()
        guard version != self.version else { return nil }
        return (snapshot(), self.version)
    }

    /// What changed in a version, for a caller keeping its own copy up to date.
    public struct Step: Sendable {
        /// Plays new in this version.
        public let added: [CaptureStat]
        /// Plays that read differently now, as they read before and after.
        public let changed: [(old: CaptureStat, new: CaptureStat)]
    }

    /// What's changed since `version`, or nil if it's still at `version`.
    public enum Change: Sendable {
        /// Everything, when the steps since can't be told: a play deleted, a first read, or a
        /// caller that's been away too long.
        case everything(Snapshot)
        /// Each version's step in turn, and every session as it is now.
        case steps([Step], sessions: [SessionStat])
    }

    /// Like ``snapshot(after:)``, but as the steps since `version` where it can, so a caller
    /// holding the history can bring it up to date without starting again from every play.
    public func changes(after version: Int?) throws -> (change: Change, version: Int)? {
        try update()
        guard version != self.version else { return nil }
        if let version, version >= stepsBase, version < self.version {
            let steps = log.filter { $0.version > version }.map(\.step)
            return (.steps(steps, sessions: sessions.values.map(\.stat)), self.version)
        }
        return (.everything(snapshot()), self.version)
    }

    /// The step each version since ``stepsBase`` took, oldest first.
    private var log: [(version: Int, step: Step)] = []
    /// The version from which every later one is in ``log``.
    private var stepsBase = Int.max
    /// The longest ``log`` gets. A caller further behind reads everything.
    private static let logLimit = 500
    /// Gathered while an update runs, for its entry in ``log``.
    private var adding: [CaptureStat] = []
    private var changing: [(old: CaptureStat, new: CaptureStat)] = []
    private var removing = false

    private func record(old: CaptureStat?, new: CaptureStat) {
        if let old {
            if old != new { changing.append((old, new)) }
        } else {
            adding.append(new)
        }
    }

    /// Brings what the reader holds up to date with the store.
    public func update() throws {
        let context = ModelContext(container)
        guard hasRead, !historyUnavailable else {
            try readEverything(context)
            return
        }

        let transactions: [DefaultHistoryTransaction]
        do {
            transactions = try Self.transactions(after: token, in: context)
        } catch let error as SwiftDataError where error == .historyTokenExpired {
            try readEverything(context)
            return
        }
        guard let latest = transactions.last?.token else {
            lastRead = .unchanged
            return
        }

        var changedCaptures = Set<PersistentIdentifier>()
        var changedSessions = Set<PersistentIdentifier>()
        var stationsChanged = false
        for transaction in transactions {
            for change in transaction.changes {
                let id = change.changedPersistentIdentifier
                switch id.entityName {
                case Self.captureEntity: changedCaptures.insert(id)
                case Self.sessionEntity: changedSessions.insert(id)
                case Self.stationEntity: stationsChanged = true
                default: break
                }
            }
        }
        guard changedCaptures.count + changedSessions.count <= Self.incrementalLimit else {
            try readEverything(context)
            return
        }
        guard !changedCaptures.isEmpty || !changedSessions.isEmpty || stationsChanged else {
            token = latest
            lastRead = .unchanged
            return
        }

        (adding, changing, removing) = ([], [], false)
        defer { (adding, changing, removing) = ([], [], false) }
        let sessionsMoved = try updateSessions(stationsChanged ? nil : changedSessions, in: context)
        let capturesMoved = try updateCaptures(changedCaptures, in: context)
        token = latest
        // Most saves after a song is kept touch nothing a snapshot holds: the playlist write,
        // the scrobble and its hold. Each used to hand every caller a new snapshot, and the
        // app rebuilt the whole history, its mixes and every screen's statistics for it.
        guard sessionsMoved || capturesMoved else {
            lastRead = .unchanged
            return
        }
        lastRead = .incremental
        version += 1
        // Here, once the plays are all in place, and never during a full read, whose plays
        // aren't yet.
        if songsSincePruning > Self.songsBetweenPruning { pruneSongs() }
        if removing {
            log = []
            stepsBase = version
        } else {
            log.append((version, Step(added: adding, changed: changing)))
            if log.count > Self.logLimit { stepsBase = log.removeFirst().version }
        }
    }

    // MARK: - Lookups

    /// Every cover address in the history, once each, sorted.
    public func artworkURLs() throws -> [String] {
        try update()
        return Set(captures.values.compactMap(\.artworkURL)).sorted()
    }

    /// Every play of a song, by ``CaptureStat/songIdentity``.
    public func captureIDs(ofSong identity: String) throws -> [PersistentIdentifier] {
        try update()
        return captures.compactMap { $0.value.songIdentity == identity ? $0.key : nil }
    }

    // MARK: - Duplicates

    /// Every play of each song that has two plays close enough to be one, by the same rule
    /// ``TracksStore/mergeDuplicateCaptures(policy:)`` merges on.
    ///
    /// The merge used to read every capture to find the few duplicates, on the main actor,
    /// after every batch from iCloud and every minute while capturing: four seconds each time
    /// in a long history. This finds them in what the reader already holds.
    ///
    /// A group is all of the song's plays, not just the pair: which plays a merge treats as
    /// one depends on every play of the song, and every device has to reach the same answer.
    public func duplicatePlayGroups(policy: DedupePolicy) throws -> [[PersistentIdentifier]] {
        try update()
        // The Mac asks every minute while it listens, and every batch from iCloud asks again.
        // With nothing changed since, the answer is the same, so it isn't worked out again
        // over every play.
        if let found = foundDuplicates, found.version == version, found.policy == policy {
            return found.groups
        }
        let groups = Self.duplicatePlayGroups(in: captures, policy: policy)
        foundDuplicates = (version, policy, groups)
        return groups
    }

    private var foundDuplicates: (version: Int, policy: DedupePolicy, groups: [[PersistentIdentifier]])?

    private static func duplicatePlayGroups(
        in captures: [PersistentIdentifier: CaptureStat],
        policy: DedupePolicy
    ) -> [[PersistentIdentifier]] {
        var bySong: [String: [(id: PersistentIdentifier, capture: CaptureStat)]] = [:]
        for (id, capture) in captures {
            bySong[capture.songIdentity, default: []].append((id, capture))
        }
        return bySong.values.compactMap { plays in
            guard plays.count > 1 else { return nil }
            let ordered = plays.sorted { $0.capture.capturedAt < $1.capture.capturedAt }
            // The clustering in `TracksStore.playClusters`: each play is measured from the
            // first play of the cluster it might join. Plays at the same moment always fall
            // in one cluster, so how ties are ordered doesn't change whether one forms.
            var anchor = ordered[0].capture
            for play in ordered.dropFirst() {
                let window = policy.mergeWindow(earlier: anchor.kind, later: play.capture.kind)
                if play.capture.capturedAt.timeIntervalSince(anchor.capturedAt) < window {
                    return plays.map(\.id)
                }
                anchor = play.capture
            }
            return nil
        }
    }

    // MARK: - Full read

    private func readEverything(_ context: ModelContext) throws {
        // Every play is read again, so the songs they share start again too.
        songs = [:]
        songsSincePruning = 0
        // The token is taken before the rows, so a save landing in between is in the next
        // read's history as well as possibly in these rows. Applying a change twice is
        // harmless; missing one isn't.
        do {
            token = try Self.latestToken(in: context)
            historyUnavailable = false
        } catch {
            token = nil
            historyUnavailable = true
        }

        var sessionRows: [PersistentIdentifier: SessionRow] = [:]
        var sessionOfCapture: [PersistentIdentifier: PersistentIdentifier] = [:]
        // Walking each session's captures is much cheaper than faulting every capture's
        // session in turn.
        for session in try context.fetch(FetchDescriptor<Session>()) {
            let captureIDs = Set((session.captures ?? []).map(\.persistentModelID))
            sessionRows[session.persistentModelID] = SessionRow(stat: Self.stat(for: session), captureIDs: captureIDs)
            for captureID in captureIDs { sessionOfCapture[captureID] = session.persistentModelID }
        }

        var captures: [PersistentIdentifier: CaptureStat] = [:]
        var descriptor = FetchDescriptor<Capture>()
        descriptor.propertiesToFetch = Self.captureProperties
        for capture in try context.fetch(descriptor) {
            let id = capture.persistentModelID
            let station = sessionOfCapture[id].flatMap { sessionRows[$0]?.stat.stationName }
            captures[id] = stat(for: capture, stationName: station)
        }

        self.sessions = sessionRows
        self.sessionOfCapture = sessionOfCapture
        self.captures = captures
        hasRead = true
        lastRead = .full
        version += 1
        songsSincePruning = 0
        log = []
        stepsBase = version
    }

    // MARK: - Incremental read

    /// Fetches the given sessions again, or every session when `ids` is nil (a station was
    /// renamed, merged or deleted, which can change any session's station name). Plays whose
    /// station name changed are updated in place.
    /// - Returns: whether any play or session now reads differently.
    private func updateSessions(_ ids: Set<PersistentIdentifier>?, in context: ModelContext) throws -> Bool {
        if let ids, ids.isEmpty { return false }
        var moved = false

        let fetched: [Session]
        if let ids {
            fetched = try Self.fetch(Session.self, ids: ids, in: context)
        } else {
            fetched = try context.fetch(FetchDescriptor<Session>())
        }
        let found = Set(fetched.map(\.persistentModelID))
        let gone = (ids ?? Set(sessions.keys)).subtracting(found)
        for id in gone {
            guard let row = sessions.removeValue(forKey: id) else { continue }
            moved = true
            for captureID in row.captureIDs {
                sessionOfCapture[captureID] = nil
                guard let old = captures[captureID] else { continue }
                let new = old.with(stationName: nil)
                record(old: old, new: new)
                captures[captureID] = new
            }
        }

        for session in fetched {
            let id = session.persistentModelID
            let stat = Self.stat(for: session)
            let captureIDs = sessions[id]?.captureIDs ?? []
            if sessions[id]?.stat != stat { moved = true }
            if sessions[id]?.stat.stationName != stat.stationName {
                for captureID in captureIDs {
                    guard let old = captures[captureID] else { continue }
                    let new = old.with(stationName: stat.stationName)
                    record(old: old, new: new)
                    captures[captureID] = new
                }
            }
            sessions[id] = SessionRow(stat: stat, captureIDs: captureIDs)
        }
        return moved
    }

    /// Fetches the given captures again. Any that no longer exist are removed.
    /// - Returns: whether any play was added, removed or now reads differently.
    private func updateCaptures(_ ids: Set<PersistentIdentifier>, in context: ModelContext) throws -> Bool {
        guard !ids.isEmpty else { return false }
        let fetched = try Self.fetch(Capture.self, ids: ids, in: context)
        var moved = false

        for id in ids.subtracting(fetched.map(\.persistentModelID)) {
            if captures.removeValue(forKey: id) != nil {
                moved = true
                removing = true
            }
            detach(id)
        }
        for capture in fetched {
            let id = capture.persistentModelID
            let sessionID = capture.session?.persistentModelID
            if sessionOfCapture[id] != sessionID {
                detach(id)
                if let sessionID {
                    sessionOfCapture[id] = sessionID
                    sessions[sessionID]?.captureIDs.insert(id)
                }
            }
            let station = sessionID.flatMap { sessions[$0]?.stat.stationName }
            let stat = stat(for: capture, stationName: station)
            if captures[id] != stat {
                moved = true
                record(old: captures[id], new: stat)
            }
            captures[id] = stat
        }
        return moved
    }

    private func detach(_ captureID: PersistentIdentifier) {
        guard let sessionID = sessionOfCapture.removeValue(forKey: captureID) else { return }
        sessions[sessionID]?.captureIDs.remove(captureID)
    }

    private func snapshot() -> Snapshot {
        Snapshot(captures: Array(captures.values), sessions: sessions.values.map(\.stat))
    }

    // MARK: - Store access

    private static let captureEntity = Schema.entityName(for: Capture.self)
    private static let sessionEntity = Schema.entityName(for: Session.self)
    private static let stationEntity = Schema.entityName(for: Station.self)

    private static var captureProperties: [PartialKeyPath<Capture>] {[
        \.songKey, \.songID, \.title, \.artistName, \.albumTitle, \.artworkURL,
        \.capturedAt, \.playedBackAt, \.kindRawValue, \.sourceRawValue,
    ]}

    /// The play as a value, its song shared with every other play of the same row content.
    ///
    /// The store hands back new strings for every row, many of them bridged, so a long
    /// history held the same names hundreds of thousands of times over, with the folding
    /// done again for each.
    private func stat(for capture: Capture, stationName: String?) -> CaptureStat {
        let key = SongKey(
            songKey: capture.songKey, songID: capture.songID, title: capture.title,
            artistName: capture.artistName, albumTitle: capture.albumTitle, artworkURL: capture.artworkURL
        )
        let song: CaptureStat.Song
        if let known = songs[key] {
            song = known
        } else {
            let native = key.native
            song = CaptureStat.Song(
                songKey: native.songKey, songID: native.songID, title: native.title,
                artistName: native.artistName, albumTitle: native.albumTitle, artworkURL: native.artworkURL
            )
            songs[native] = song
            songsSincePruning += 1
        }
        return CaptureStat(
            song: song,
            capturedAt: capture.capturedAt,
            stationName: stationName.map(station),
            playedBackAt: capture.playedBackAt,
            kind: capture.kind,
            source: capture.source
        )
    }

    /// Each row content's song, once.
    private var songs: [SongKey: CaptureStat.Song] = [:]
    private var songsSincePruning = 0
    /// A cover found or an id resolved makes a new song for the row, and the old one stays
    /// here until it's pruned, after this many new ones.
    private static let songsBetweenPruning = 5_000

    /// Keeps only the songs some play still has.
    private func pruneSongs() {
        songsSincePruning = 0
        var kept: [SongKey: CaptureStat.Song] = [:]
        for capture in captures.values {
            let song = capture.song
            kept[SongKey(
                songKey: song.songKey, songID: song.songID, title: song.title,
                artistName: song.artistName, albumTitle: song.albumTitle, artworkURL: song.artworkURL
            )] = song
        }
        songs = kept
    }
    /// Each station's name, once.
    private var stationNames: [String: String] = [:]

    private func station(_ name: String) -> String {
        if let known = stationNames[name] { return known }
        let native = SongKey.native(name)
        stationNames[native] = native
        return native
    }

    private struct SongKey: Hashable {
        let songKey: String
        let songID: String
        let title: String
        let artistName: String
        let albumTitle: String?
        let artworkURL: String?

        /// The same, as Swift's own strings rather than ones bridged from the store.
        var native: SongKey {
            SongKey(
                songKey: Self.native(songKey), songID: Self.native(songID), title: Self.native(title),
                artistName: Self.native(artistName), albumTitle: albumTitle.map(Self.native),
                artworkURL: artworkURL.map(Self.native)
            )
        }

        static func native(_ string: String) -> String {
            var copy = string
            copy.makeContiguousUTF8()
            return copy
        }
    }

    private static func stat(for session: Session) -> SessionStat {
        SessionStat(
            startedAt: session.startedAt,
            finishedAt: session.endedAt ?? session.lastActivityAt,
            stationName: session.station?.name
        )
    }

    private static func fetch<Model: PersistentModel>(
        _ type: Model.Type,
        ids: Set<PersistentIdentifier>,
        in context: ModelContext
    ) throws -> [Model] {
        let all = Array(ids)
        var result: [Model] = []
        for start in stride(from: 0, to: all.count, by: fetchChunk) {
            let chunk = Array(all[start..<min(start + fetchChunk, all.count)])
            let descriptor = FetchDescriptor<Model>(
                predicate: #Predicate { chunk.contains($0.persistentModelID) }
            )
            result += try context.fetch(descriptor)
        }
        return result
    }

    static func latestToken(in context: ModelContext) throws -> DefaultHistoryToken? {
        var descriptor = HistoryDescriptor<DefaultHistoryTransaction>(
            sortBy: [SortDescriptor(\.transactionIdentifier, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetchHistory(descriptor).first?.token
    }

    static func transactions(
        after token: DefaultHistoryToken?,
        in context: ModelContext
    ) throws -> [DefaultHistoryTransaction] {
        guard let token else {
            return try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>())
        }
        return try context.fetchHistory(HistoryDescriptor<DefaultHistoryTransaction>(
            predicate: #Predicate { $0.token > token }
        ))
    }
}

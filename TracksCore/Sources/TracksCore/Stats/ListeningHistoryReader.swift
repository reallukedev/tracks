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

        try updateSessions(stationsChanged ? nil : changedSessions, in: context)
        try updateCaptures(changedCaptures, in: context)
        token = latest
        lastRead = .incremental
        version += 1
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
            captures[id] = Self.stat(for: capture, stationName: station)
        }

        self.sessions = sessionRows
        self.sessionOfCapture = sessionOfCapture
        self.captures = captures
        hasRead = true
        lastRead = .full
        version += 1
    }

    // MARK: - Incremental read

    /// Fetches the given sessions again, or every session when `ids` is nil (a station was
    /// renamed, merged or deleted, which can change any session's station name). Plays whose
    /// station name changed are updated in place.
    private func updateSessions(_ ids: Set<PersistentIdentifier>?, in context: ModelContext) throws {
        if let ids, ids.isEmpty { return }

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
            for captureID in row.captureIDs {
                sessionOfCapture[captureID] = nil
                captures[captureID] = captures[captureID]?.with(stationName: nil)
            }
        }

        for session in fetched {
            let id = session.persistentModelID
            let stat = Self.stat(for: session)
            let captureIDs = sessions[id]?.captureIDs ?? []
            if sessions[id]?.stat.stationName != stat.stationName {
                for captureID in captureIDs {
                    captures[captureID] = captures[captureID]?.with(stationName: stat.stationName)
                }
            }
            sessions[id] = SessionRow(stat: stat, captureIDs: captureIDs)
        }
    }

    /// Fetches the given captures again. Any that no longer exist are removed.
    private func updateCaptures(_ ids: Set<PersistentIdentifier>, in context: ModelContext) throws {
        guard !ids.isEmpty else { return }
        let fetched = try Self.fetch(Capture.self, ids: ids, in: context)

        for id in ids.subtracting(fetched.map(\.persistentModelID)) {
            captures[id] = nil
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
            captures[id] = Self.stat(for: capture, stationName: station)
        }
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

    private static func stat(for capture: Capture, stationName: String?) -> CaptureStat {
        CaptureStat(
            songKey: capture.songKey,
            songID: capture.songID,
            title: capture.title,
            artistName: capture.artistName,
            albumTitle: capture.albumTitle,
            artworkURL: capture.artworkURL,
            capturedAt: capture.capturedAt,
            stationName: stationName,
            playedBackAt: capture.playedBackAt,
            kind: capture.kind,
            source: capture.source
        )
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

import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Which row of a merged play survives, and what it keeps from the rows that don't.
///
/// Every device merges its own copy and the deletions sync, so the survivor has to be the
/// same row everywhere, and deleting the others must not lose what they knew.
@MainActor
@Suite("Capture merge survivor")
struct CaptureMergeSurvivorTests {
    let store: TracksStore
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let policy = DedupePolicy()

    init() throws {
        store = try TracksStore(inMemory: true)
    }

    @discardableResult
    func insert(
        _ kind: CaptureKind,
        at offset: TimeInterval,
        device: String,
        songKey: String = "1",
        session: Session? = nil
    ) -> Capture {
        let capture = Capture(
            songID: "1", songKey: songKey, title: "Fireside", artistName: "Giant Book Sale",
            kind: kind, capturedAt: start.addingTimeInterval(offset), deviceID: device,
            session: session
        )
        store.context.insert(capture)
        return capture
    }

    func remaining() throws -> [Capture] {
        try store.context.fetch(TracksStore.allCaptures())
    }

    // MARK: - Import, then the witnessed row

    /// The reported case: the iPhone imports a play from Recently Played, then the Mac's
    /// witnessed row of it syncs in 30 seconds later. The oldest row used to win, so the
    /// import deleted the witnessed row and everything only it knew.
    @Test("a witnessed row after an import survives with its kind, session and queues")
    func witnessedAfterImportSurvives() throws {
        let session = Session(startedAt: start, deviceID: "mac")
        store.context.insert(session)
        insert(.imported, at: 0, device: "phone")
        let witnessed = insert(.radio, at: 30, device: "mac", session: session)
        try store.context.save()
        #expect(witnessed.needsPlaylistWrite)

        #expect(try store.mergeDuplicateCaptures(policy: policy) == 1)

        let survivor = try #require(try remaining().first)
        #expect(try remaining().count == 1)
        #expect(survivor.kind == .radio)
        #expect(survivor.capturedAt == start.addingTimeInterval(30))
        #expect(survivor.capturedByDeviceID == "mac")
        #expect(survivor.session === session)
        // Still owed its playlist write, on the device that witnessed it.
        #expect(survivor.needsPlaylistWrite)
        #expect(survivor.scrobbledAt == nil)
    }

    /// Fetch order is not something devices agree on.
    @Test("the same row survives whichever order the rows were inserted in")
    func survivorIgnoresInsertionOrder() throws {
        let other = try TracksStore(inMemory: true)
        for (target, reversed) in [(store, false), (other, true)] {
            let rows: [(CaptureKind, TimeInterval, String)] = [
                (.imported, 0, "phone"), (.onDemand, 20, "ipad"), (.radio, 40, "mac"), (.imported, 60, "mac"),
            ]
            for (kind, offset, device) in reversed ? rows.reversed() : rows {
                target.context.insert(Capture(
                    songID: "1", title: "Fireside", artistName: "Giant Book Sale",
                    kind: kind, capturedAt: start.addingTimeInterval(offset), deviceID: device
                ))
            }
            try target.context.save()
            #expect(try target.mergeDuplicateCaptures(policy: policy) == 3)
        }

        let first = try #require(try store.context.fetch(TracksStore.allCaptures()).first)
        let second = try #require(try other.context.fetch(TracksStore.allCaptures()).first)
        #expect(first.kind == .radio)
        #expect((first.kind, first.capturedAt, first.capturedByDeviceID)
            == (second.kind, second.capturedAt, second.capturedByDeviceID))
    }

    @Test("rows of one kind at the same instant still pick one survivor everywhere")
    func exactTiesAreBrokenTheSameWay() {
        let a = Capture(songID: "1", title: "T", artistName: "A", kind: .radio, capturedAt: start, deviceID: "a")
        let b = Capture(songID: "1", title: "T", artistName: "A", kind: .radio, capturedAt: start, deviceID: "b")
        #expect(TracksStore.isPreferredSurvivor(a, over: b))
        #expect(!TracksStore.isPreferredSurvivor(b, over: a))
    }

    // MARK: - What the survivor absorbs

    @Test("a duplicate already in the playlist stops the survivor being written again")
    func playlistStateMerges() throws {
        let imported = insert(.imported, at: 0, device: "phone")
        imported.addedToPlaylistAt = start.addingTimeInterval(5)
        insert(.radio, at: 30, device: "mac")
        try store.context.save()

        try store.mergeDuplicateCaptures(policy: policy)

        let survivor = try #require(try remaining().first)
        #expect(survivor.kind == .radio)
        #expect(survivor.addedToPlaylistAt == start.addingTimeInterval(5))
        #expect(!survivor.needsPlaylistWrite)
    }

    @Test("a duplicate already scrobbled stops the survivor being scrobbled again")
    func scrobbleStateMerges() throws {
        let imported = insert(.imported, at: 0, device: "phone")
        imported.scrobbledAt = start.addingTimeInterval(10)
        insert(.onDemand, at: 30, device: "mac")
        try store.context.save()

        try store.mergeDuplicateCaptures(policy: policy)

        let survivor = try #require(try remaining().first)
        #expect(survivor.kind == .onDemand)
        #expect(survivor.scrobbledAt == start.addingTimeInterval(10))
        #expect(try store.context.fetch(
            TracksStore.pendingScrobbles(deviceID: "mac", includingImported: true)
        ).isEmpty)
    }

    @Test("the survivor takes a session, artwork and album it didn't have")
    func metadataMerges() throws {
        let session = Session(startedAt: start, deviceID: "mac")
        store.context.insert(session)
        let earlier = insert(.radio, at: 0, device: "phone")
        earlier.artworkURL = "musicKit://artwork/transient/abc"
        let later = insert(.radio, at: 60, device: "mac", session: session)
        later.artworkURL = "https://example.test/cover.jpg"
        later.albumTitle = "Album"
        later.playedBackAt = start.addingTimeInterval(3_600)
        try store.context.save()

        try store.mergeDuplicateCaptures(policy: policy)

        let survivor = try #require(try remaining().first)
        #expect(survivor.capturedByDeviceID == "phone")
        #expect(survivor.session === session)
        #expect(survivor.artworkURL == "https://example.test/cover.jpg")
        #expect(survivor.albumTitle == "Album")
        #expect(survivor.playedBackAt == start.addingTimeInterval(3_600))
    }

    // MARK: - Windows and stability

    @Test("an import 23 hours after a witnessed play is that play")
    func importInsideImportWindowMerges() throws {
        insert(.radio, at: 0, device: "mac")
        insert(.imported, at: 23 * 3_600, device: "phone")
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: policy) == 1)
        #expect(try remaining().map(\.kind) == [.radio])
    }

    @Test("an import 25 hours after a witnessed play is another play")
    func importOutsideImportWindowStays() throws {
        insert(.radio, at: 0, device: "mac")
        insert(.imported, at: 25 * 3_600, device: "phone")
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: policy) == 0)
        #expect(try remaining().count == 2)
    }

    @Test("two imports 23 hours apart are one play, 25 hours apart are two")
    func importPairBoundaries() throws {
        insert(.imported, at: 0, device: "mac", songKey: "a")
        insert(.imported, at: 23 * 3_600, device: "phone", songKey: "b")
        insert(.imported, at: 48 * 3_600, device: "phone", songKey: "c")
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: policy) == 1)
        #expect(try remaining().count == 2)
    }

    /// The window is measured from a play's first row, not from its survivor, so a later
    /// survivor doesn't stretch the play; and a second run finds nothing more to do.
    @Test("merging twice changes nothing the second time")
    func mergeIsIdempotent() throws {
        insert(.imported, at: 0, device: "phone")
        insert(.radio, at: 5 * 60, device: "mac")
        // Outside the ordinary window from the first row, inside it from the survivor.
        insert(.radio, at: 12 * 60, device: "ipad")
        insert(.radio, at: 40 * 60, device: "ipad")
        try store.context.save()

        let first = try store.mergeDuplicateCaptures(policy: policy)
        #expect(first == 2)
        #expect(try store.mergeDuplicateCaptures(policy: policy) == 0)
        #expect(try remaining().map(\.capturedAt).sorted()
            == [start.addingTimeInterval(5 * 60), start.addingTimeInterval(40 * 60)])
    }

    @Test("witnessed rows further apart than the ordinary window stay separate plays")
    func witnessedRowsOutsideWindowStay() throws {
        insert(.radio, at: 0, device: "mac")
        insert(.onDemand, at: 11 * 60, device: "phone")
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: policy) == 0)
    }

    // MARK: - Exact copies

    /// Motif's history brought over on two devices at once gives two identical rows. Each
    /// device kept its own copy and deleted the other's, so the play was lost everywhere.
    @Test("exact copies of a play are both kept rather than risking both")
    func exactCopiesStay() throws {
        insert(.radio, at: 0, device: "motif")
        insert(.radio, at: 0, device: "motif")
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: policy) == 0)
        #expect(try remaining().count == 2)
    }

    @Test("rows that differ still merge as before")
    func differingRowsStillMerge() throws {
        insert(.radio, at: 0, device: "mac")
        insert(.imported, at: 60, device: "phone")
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: policy) == 1)
    }

    @Test("stations that can't be told apart are both kept")
    func exactStationCopiesStay() throws {
        store.context.insert(Station(name: "Chill", firstSeenAt: start))
        store.context.insert(Station(name: "Chill", firstSeenAt: start))
        store.context.insert(Station(name: "Rock", firstSeenAt: start))
        store.context.insert(Station(name: "rock", firstSeenAt: start.addingTimeInterval(60)))
        try store.context.save()

        #expect(try store.mergeDuplicateStations() == 1)
        #expect(try store.context.fetch(FetchDescriptor<Station>()).count == 3)
    }
}

import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Problems that only exist once the store syncs: rows written by another device, and
/// station rows that two devices each created.
@MainActor
@Suite("iCloud sync reconciliation")
struct CloudSyncTests {

    /// `Station.sessions` used to cascade, so deleting the duplicate before moving its
    /// sessions deleted listening history. It nullifies now, but the sessions must still
    /// end up on the survivor rather than with no station.
    @Test("merging stations keeps the sessions that belonged to the duplicate")
    func mergeKeepsSessions() throws {
        let store = try TracksStore(inMemory: true)
        let older = Station(name: "Apple Music Chill", firstSeenAt: .now.addingTimeInterval(-3600))
        let newer = Station(name: "Apple Music Chill", firstSeenAt: .now)
        store.context.insert(older)
        store.context.insert(newer)
        store.context.insert(Session(startedAt: .now.addingTimeInterval(-3600), station: older))
        store.context.insert(Session(startedAt: .now, station: newer))
        try store.context.save()

        #expect(try store.mergeDuplicateStations() == 1)

        let stations = try store.context.fetch(FetchDescriptor<Station>())
        let sessions = try store.context.fetch(FetchDescriptor<Session>())
        #expect(stations.count == 1)
        #expect(sessions.count == 2)
        #expect(sessions.allSatisfy { $0.station === stations.first })
    }

    /// Each device merges on its own, so the winner has to be one they all pick: the oldest.
    @Test("the oldest station survives and absorbs what the others knew")
    func mergePrefersTheOldest() throws {
        let store = try TracksStore(inMemory: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let older = Station(name: "Chill", firstSeenAt: start)
        // Only the iPhone learns a catalog id.
        let newer = Station(name: "Chill", catalogID: "ra.123", firstSeenAt: start.addingTimeInterval(60))
        newer.lastSeenAt = start.addingTimeInterval(9_000)
        store.context.insert(older)
        store.context.insert(newer)
        try store.context.save()

        try store.mergeDuplicateStations()

        let survivor = try #require(try store.context.fetch(FetchDescriptor<Station>()).first)
        #expect(survivor.firstSeenAt == start)
        #expect(survivor.catalogID == "ra.123")
        #expect(survivor.lastSeenAt == start.addingTimeInterval(9_000))
    }

    @Test("case and accents do not make two stations")
    func mergeIgnoresCaseAndAccents() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Station(name: "Café Radio", firstSeenAt: .now.addingTimeInterval(-60)))
        store.context.insert(Station(name: "cafe radio", firstSeenAt: .now))
        try store.context.save()

        #expect(try store.mergeDuplicateStations() == 1)
        #expect(try store.context.fetch(FetchDescriptor<Station>()).count == 1)
    }

    @Test("distinct stations are left alone")
    func mergeLeavesDistinctStationsAlone() throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Station(name: "Chill", firstSeenAt: .now))
        store.context.insert(Station(name: "Hits", firstSeenAt: .now))
        try store.context.save()

        #expect(try store.mergeDuplicateStations() == 0)
        #expect(try store.context.fetch(FetchDescriptor<Station>()).count == 2)
    }

    /// The playlist syncs too, so if both devices wrote every row each song would go in twice.
    @Test("the playlist queue only offers rows this device recorded")
    func playlistQueueIsScopedToThisDevice() throws {
        let store = try TracksStore(inMemory: true)
        let mine = Capture(
            songID: "1", title: "Mine", artistName: "A", deviceID: "this-device"
        )
        let theirs = Capture(
            songID: "2", title: "Theirs", artistName: "B", deviceID: "other-device"
        )
        store.context.insert(mine)
        store.context.insert(theirs)
        try store.context.save()

        #expect(mine.needsPlaylistWrite)
        #expect(theirs.needsPlaylistWrite)

        let pending = try store.context.fetch(
            TracksStore.pendingPlaylistWrites(deviceID: "this-device")
        )
        #expect(pending.map(\.title) == ["Mine"])
    }

    /// Rows from before sync have no device id. The first synced launch stamps them with its
    /// own, or the scoped queue would never pick them up.
    @Test("a capture with no device id is not in any device's queue until stamped")
    func unstampedRowsAreNotClaimed() throws {
        let store = try TracksStore(inMemory: true)
        let legacy = Capture(songID: "1", title: "Old", artistName: "A", deviceID: "")
        store.context.insert(legacy)
        try store.context.save()

        #expect(try store.context.fetch(
            TracksStore.pendingPlaylistWrites(deviceID: "this-device")
        ).isEmpty)

        legacy.capturedByDeviceID = "this-device"
        try store.context.save()

        #expect(try store.context.fetch(
            TracksStore.pendingPlaylistWrites(deviceID: "this-device")
        ).count == 1)
    }

    @Test("the device identifier persists once generated")
    func deviceIdentifierIsStable() {
        let first = DeviceIdentity.current
        #expect(!first.isEmpty)
        #expect(DeviceIdentity.current == first)
    }

    /// `swift test` has no Info.plist key, so sync isn't configured. The store should still open.
    @Test("a build with no container configured still opens its store")
    func missingContainerIsNotAFailure() throws {
        #expect(CloudSync.containerIdentifier == nil)
        let store = try TracksStore(inMemory: true, sync: true)
        #expect(!store.backing.isSynced)
        #expect(store.syncFailureReason == nil)
    }
}

/// Two devices hearing one play.
///
/// A station playing on the Mac also shows in the iPhone's system player, so both capture
/// it, keyed differently (iOS has the catalog id, macOS doesn't). Seen on 2026-09-08 as a
/// doubled row and a song added to the playlist twice.
@MainActor
@Suite("Cross-device capture duplicates")
struct CaptureMergeTests {

    private func capture(
        _ songID: String,
        key: String,
        at when: Date,
        device: String,
        playlistAt: Date? = nil,
        artwork: String? = nil
    ) -> Capture {
        let capture = Capture(
            songID: songID, songKey: key, title: "Fireside", artistName: "Giant Book Sale",
            artworkURL: artwork, capturedAt: when, deviceID: device
        )
        capture.addedToPlaylistAt = playlistAt
        if playlistAt != nil { capture.needsPlaylistWrite = false }
        return capture
    }

    @Test("the same play seen by two devices becomes one row")
    func mergesAcrossDevices() throws {
        let store = try TracksStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // As observed: iOS keyed on the catalog id, macOS on title and artist.
        store.context.insert(capture("1814555105", key: "fireside\u{1F}giant book sale", at: now, device: "mac"))
        store.context.insert(capture("1814555105", key: "1814555105", at: now.addingTimeInterval(2), device: "phone"))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
        let remaining = try store.context.fetch(TracksStore.radioCaptures())
        try #require(remaining.count == 1)
        // The earlier row survives.
        #expect(remaining[0].capturedAt == now)
        #expect(remaining[0].capturedByDeviceID == "mac")
    }

    @Test("the same song heard again later is two plays, not a duplicate")
    func keepsGenuineRepeats() throws {
        let store = try TracksStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(capture("1814555105", key: "a", at: now, device: "mac"))
        store.context.insert(capture("1814555105", key: "b", at: now.addingTimeInterval(7200), device: "mac"))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 0)
        #expect(try store.context.fetch(TracksStore.radioCaptures()).count == 2)
    }

    /// The Mac's row is the earlier one, so it survives, and it is the row that has *not*
    /// been added: the playlist date has to come across from the phone's row as it goes.
    @Test("a survivor never re-writes a song the other row already added")
    func doesNotRewriteToPlaylist() throws {
        let store = try TracksStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let addedOnPhone = now.addingTimeInterval(3)
        let mine = capture("1814555105", key: "a", at: now, device: "mac")
        store.context.insert(mine)
        store.context.insert(capture(
            "1814555105", key: "b", at: now.addingTimeInterval(2), device: "phone",
            playlistAt: addedOnPhone
        ))
        try store.context.save()
        #expect(mine.needsPlaylistWrite)
        #expect(mine.addedToPlaylistAt == nil)

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
        let remaining = try store.context.fetch(TracksStore.radioCaptures())
        try #require(remaining.count == 1)
        let survivor = remaining[0]
        #expect(survivor.capturedByDeviceID == "mac")
        #expect(survivor.songKey == "a")
        #expect(!survivor.needsPlaylistWrite)
        #expect(survivor.addedToPlaylistAt == addedOnPhone)
    }

    /// As above: the Mac's earlier row survives, and only the phone's row had a cover.
    @Test("the survivor inherits artwork the other row had")
    func inheritsArtwork() throws {
        let store = try TracksStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let mine = capture("1814555105", key: "a", at: now, device: "mac")
        store.context.insert(mine)
        store.context.insert(capture(
            "1814555105", key: "b", at: now.addingTimeInterval(2), device: "phone",
            artwork: "https://example.com/cover.jpg"
        ))
        try store.context.save()
        #expect(mine.artworkURL == nil)

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
        let remaining = try store.context.fetch(TracksStore.radioCaptures())
        try #require(remaining.count == 1)
        let survivor = remaining[0]
        #expect(survivor.capturedByDeviceID == "mac")
        #expect(survivor.songKey == "a")
        #expect(survivor.artworkURL == "https://example.com/cover.jpg")
    }

    @Test("unresolved rows merge too")
    func mergesUnresolvedRows() throws {
        let store = try TracksStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(capture("", key: "a", at: now, device: "mac"))
        store.context.insert(capture("", key: "b", at: now.addingTimeInterval(2), device: "phone"))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
    }

    // MARK: - Plays that must survive the merge

    /// Reported 2026-09-15 as "my iPhone is missing a bunch of songs from my Mac".
    ///
    /// The window check used to be skipped whenever either row was an import, so any two
    /// rows of one song merged however far apart they were. On iPhone, imports from Recently
    /// Played are most of the history, so every repeat play of a song was deleted, and the
    /// deletion synced, taking it off the Mac too.
    @Test("plays of one song a month apart are four plays, not one")
    func repeatImportedPlaysSurvive() throws {
        let store = try TracksStore(inMemory: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for month in 0..<4 {
            store.context.insert(Capture(
                songID: "1", songKey: "1", title: "Fireside", artistName: "Giant Book Sale",
                kind: .imported, capturedAt: start.addingTimeInterval(Double(month) * 30 * 86_400),
                deviceID: "phone"
            ))
        }
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 0)
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 4)
    }

    /// An import records a play that happened *before* it was found, so a witnessed play
    /// after it is a second play. The old rule let the stale import swallow the real one.
    @Test("an old import does not swallow a real play recorded weeks later")
    func oldImportDoesNotEatLaterPlay() throws {
        let store = try TracksStore(inMemory: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Fireside", artistName: "Giant Book Sale",
            kind: .imported, capturedAt: start, deviceID: "phone"
        ))
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Fireside", artistName: "Giant Book Sale",
            kind: .radio, capturedAt: start.addingTimeInterval(21 * 86_400), deviceID: "mac"
        ))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 0)
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 2)
    }

    /// The case the wide window exists for, which must keep working: the iPhone opens a
    /// while after a play the Mac witnessed, and Recently Played hands it back dated now.
    @Test("an import shortly after a witnessed play is still that play")
    func lateImportOfAWitnessedPlayStillMerges() throws {
        let store = try TracksStore(inMemory: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Fireside", artistName: "Giant Book Sale",
            kind: .radio, capturedAt: start, deviceID: "mac"
        ))
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Fireside", artistName: "Giant Book Sale",
            kind: .imported, capturedAt: start.addingTimeInterval(45 * 60), deviceID: "phone"
        ))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
        // The witnessed row is the one that survives: it has the real time and the real kind.
        let remaining = try store.context.fetch(TracksStore.allCaptures())
        try #require(remaining.count == 1)
        let survivor = remaining[0]
        #expect(survivor.kind == .radio)
        #expect(survivor.capturedAt == start)
    }

    @Test("the import window is directional", arguments: [
        (earlier: CaptureKind.radio, later: CaptureKind.imported, wide: true),
        (earlier: .imported, later: .radio, wide: false),
        // Two devices importing the same account-wide play, hours apart.
        (earlier: .imported, later: .imported, wide: true),
        (earlier: .radio, later: .radio, wide: false),
        (earlier: .onDemand, later: .imported, wide: true),
    ])
    func importWindowIsDirectional(earlier: CaptureKind, later: CaptureKind, wide: Bool) {
        let policy = DedupePolicy()
        let window = policy.mergeWindow(earlier: earlier, later: later)
        #expect(window == (wide ? policy.importWindow : policy.window))
    }

    /// Apple Music's recently-played list is account-wide, so the iPhone reads back a play
    /// that happened on the Mac and imports it dated now. If the Mac's own row hasn't synced
    /// down yet, the importer's 24-hour check can't see it and both rows exist.
    @Test("the same play imported by two devices hours apart is one play")
    func crossDeviceImportsOfOnePlayMerge() throws {
        let store = try TracksStore(inMemory: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Fireside", artistName: "Giant Book Sale",
            kind: .imported, capturedAt: start, deviceID: "mac"
        ))
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Fireside", artistName: "Giant Book Sale",
            kind: .imported, capturedAt: start.addingTimeInterval(4 * 3600), deviceID: "phone"
        ))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 1)
    }

    /// Apple's history gives a library id for a song macOS resolved to a catalog id.
    @Test("different catalog ids for one song still merge")
    func mergesAcrossDifferentIDs() throws {
        let store = try TracksStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        store.context.insert(capture("1814555105", key: "a", at: now, device: "mac"))
        store.context.insert(capture("i.vMX12aDc9LEQzar", key: "b", at: now.addingTimeInterval(2), device: "mac"))
        try store.context.save()

        #expect(try store.mergeDuplicateCaptures(policy: DedupePolicy()) == 1)
    }
}

/// Artwork URLs that look fine and load nothing.
@MainActor
@Suite("Loadable artwork")
struct LoadableArtworkTests {

    @Test("only http and https count as loadable")
    func recognisesSchemes() {
        #expect(TracksStore.isLoadableArtwork("https://example.com/a.jpg"))
        #expect(TracksStore.isLoadableArtwork("http://example.com/a.jpg"))
        // A real value that got into the database and rendered blank.
        #expect(!TracksStore.isLoadableArtwork(
            "musicKit://artwork/transient/300x300?id=605762A4%2D72F3%2D4CCA%2D9433%2DB74430729129"
        ))
        #expect(!TracksStore.isLoadableArtwork(nil))
        #expect(!TracksStore.isLoadableArtwork(""))
    }

    @Test("an unloadable URL is forgotten so the backfill retries it")
    func clearsUnloadable() throws {
        let store = try TracksStore(inMemory: true)
        let bad = Capture(
            songID: "1", title: "T", artistName: "A", artworkURL: "musicKit://artwork/x", deviceID: "this-device"
        )
        let good = Capture(
            songID: "2", title: "T2", artistName: "A", artworkURL: "https://example.com/a.jpg", deviceID: "this-device"
        )
        store.context.insert(bad)
        store.context.insert(good)
        try store.context.save()

        #expect(try store.clearUnloadableArtwork() == 1)
        #expect(bad.artworkURL == nil)
        #expect(good.artworkURL == "https://example.com/a.jpg")
    }
}

/// Folding in what iCloud brings down.
///
/// The merges themselves are covered above; this is about the pass that drives them, which
/// used to happen only at launch and on a timer that turns while capture is running.
@MainActor
@Suite("Reconciling synced changes")
struct SyncReconcilerTests {

    @Test("one pass folds in both the duplicate stations and the duplicate captures")
    func reconcileMergesBothKinds() async throws {
        let store = try TracksStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store.context.insert(Station(name: "Chill", firstSeenAt: now.addingTimeInterval(-60)))
        store.context.insert(Station(name: "Chill", firstSeenAt: now))
        // The same play, seen by the Mac and by the phone.
        store.context.insert(Capture(
            songID: "1", songKey: "chill\u{1F}band", title: "Fireside",
            artistName: "Giant Book Sale", capturedAt: now, deviceID: "mac"
        ))
        store.context.insert(Capture(
            songID: "1", songKey: "1", title: "Fireside",
            artistName: "Giant Book Sale", capturedAt: now.addingTimeInterval(2), deviceID: "phone"
        ))
        try store.context.save()

        await SyncReconciler(store: store).reconcile().value

        #expect(try store.context.fetch(FetchDescriptor<Station>()).count == 1)
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 1)
    }

    @Test("a store with nothing to merge is left alone")
    func reconcileIsSafeWhenThereIsNothingToDo() async throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Station(name: "Chill", firstSeenAt: .now))
        store.context.insert(Capture(songID: "1", title: "A", artistName: "B", deviceID: "mac"))
        try store.context.save()

        await SyncReconciler(store: store).reconcile().value

        #expect(try store.context.fetch(FetchDescriptor<Station>()).count == 1)
        #expect(try store.context.fetch(TracksStore.allCaptures()).count == 1)
    }

    /// The widgets and the open views need telling, or a merge that removed a row they're
    /// showing leaves them showing it until something else redraws them.
    @Test("reconciling says how many rows it merged away")
    func announcesMergedCount() async throws {
        let store = try TracksStore(inMemory: true)
        store.context.insert(Station(name: "Chill", firstSeenAt: .now.addingTimeInterval(-60)))
        store.context.insert(Station(name: "Chill", firstSeenAt: .now))
        try store.context.save()

        let reconciler = SyncReconciler(store: store)
        await confirmation("the merge is announced") { announced in
            // No queue, so the notification is delivered before the merge finishes, and
            // waiting for the merge means the confirmation can't be checked before it arrives.
            let observer = NotificationCenter.default.addObserver(
                forName: SyncReconciler.didReconcileNotification,
                object: reconciler,
                queue: nil
            ) { notification in
                #expect(notification.userInfo?[SyncReconciler.mergedCountKey] as? Int == 1)
                announced()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            await reconciler.reconcile().value
        }
    }
}

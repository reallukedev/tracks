import Testing
import Foundation
import SwiftData
@testable import TracksCore

/// Which saves should reload which widget. Missing one leaves a widget stale for up to 15
/// minutes; reloading on every save wastes WidgetKit's reload budget on scrobbles and
/// playlist writes.
@MainActor
@Suite("Widget faces")
struct WidgetFacesTests {
    let store: TracksStore
    /// Midday, well clear of the day boundary.
    let now = Date(timeIntervalSince1970: 1_700_049_600)
    let calendar: Calendar

    init() throws {
        store = try TracksStore(inMemory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        self.calendar = calendar
    }

    @discardableResult
    func capture(_ title: String, minutesAgo: Double, artworkURL: String? = nil) -> Capture {
        let capture = Capture(
            songID: "id-\(title)",
            title: title,
            artistName: "Artist",
            artworkURL: artworkURL,
            capturedAt: now.addingTimeInterval(-minutesAgo * 60),
            deviceID: "this-device"
        )
        store.context.insert(capture)
        return capture
    }

    /// What the app compares.
    func faces(showsUpNext: Bool = true) throws -> WidgetFaces {
        try store.widgetFaces(showsUpNext: showsUpNext, now: now, calendar: calendar)
    }

    @Test("a new capture changes every widget")
    func newCaptureChangesAll() throws {
        capture("First", minutesAgo: 10)
        try store.context.save()
        let before = try faces()

        capture("Second", minutesAgo: 1)
        try store.context.save()

        #expect(try faces().kindsChanged(since: before) == [WidgetKind.lastPlayed, WidgetKind.today, WidgetKind.listening])
    }

    /// These happen for every song and show on no widget.
    @Test("a scrobble, a playlist write and a catalog lookup change no widget")
    func bookkeepingChangesNothing() throws {
        let song = capture("Song", minutesAgo: 5)
        try store.context.save()
        let before = try faces()

        song.scrobbledAt = now
        song.needsPlaylistWrite = false
        song.addedToPlaylistAt = now
        song.catalogLookupAttempts += 1
        try store.context.save()

        #expect(try faces().kindsChanged(since: before).isEmpty)
    }

    /// The reported bug: after Play in the Today widget, played songs stayed in Up Next.
    @Test("a song played back leaves Up Next, and only Today reloads")
    func playedBackChangesToday() throws {
        let first = capture("First", minutesAgo: 20)
        capture("Second", minutesAgo: 10)
        try store.context.save()
        let before = try faces()

        first.playedBackAt = now
        try store.context.save()

        #expect(try faces().kindsChanged(since: before) == [WidgetKind.today])
    }

    /// Today without Up Next doesn't show played-back state.
    @Test("with Up Next hidden, a song played back changes nothing")
    func playedBackWithUpNextHidden() throws {
        let first = capture("First", minutesAgo: 20)
        try store.context.save()
        let before = try faces(showsUpNext: false)

        first.playedBackAt = now
        try store.context.save()

        #expect(try faces(showsUpNext: false).kindsChanged(since: before).isEmpty)
    }

    /// Mac captures get their cover from a catalog search after the row is saved.
    @Test("a cover arriving changes the widgets showing that song")
    func artworkChangesSongWidgets() throws {
        let song = capture("Song", minutesAgo: 5)
        try store.context.save()
        let before = try faces()

        song.artworkURL = "https://is1-ssl.mzstatic.com/image/thumb/cover/100x100bb.jpg"
        try store.context.save()

        #expect(try faces().kindsChanged(since: before) == [WidgetKind.lastPlayed, WidgetKind.today])
    }

    @Test("forgetting a song changes every widget it counted in")
    func forgettingChangesAll() throws {
        capture("Keep", minutesAgo: 20)
        capture("Forget", minutesAgo: 5)
        try store.context.save()
        let before = try faces()

        let suite = "com.luke.tracks.tests.\(UUID().uuidString)"
        defer { ScratchDefaults.remove(suiteName: suite) }
        try store.forgetSong(title: "Forget", artistName: "Artist", settings: CaptureSettings(suiteName: suite))

        #expect(try faces().kindsChanged(since: before) == [WidgetKind.lastPlayed, WidgetKind.today, WidgetKind.listening])
    }

    /// Recently Played can bring back a song from days ago. It isn't the latest or from
    /// today, but it adds to the week.
    @Test("a song recovered from earlier in the week changes only Listening")
    func olderSongChangesListening() throws {
        capture("Today", minutesAgo: 10)
        try store.context.save()
        let before = try faces()

        capture("Two days ago", minutesAgo: 2 * 24 * 60)
        try store.context.save()

        #expect(try faces().kindsChanged(since: before) == [WidgetKind.listening])
    }

    /// The artwork backfill touches rows below what any widget shows.
    @Test("a change below the last row any widget shows changes nothing")
    func changeOutOfSightChangesNothing() throws {
        let oldest = capture("Oldest", minutesAgo: 100)
        for index in 0..<WidgetReading.mostTodayRows {
            capture("Song \(index)", minutesAgo: Double(index))
        }
        // Played back, so it isn't in Up Next either.
        oldest.playedBackAt = now
        try store.context.save()
        let before = try faces()

        oldest.artworkURL = "https://is1-ssl.mzstatic.com/image/thumb/cover/100x100bb.jpg"
        try store.context.save()

        #expect(try faces().kindsChanged(since: before).isEmpty)
    }

    /// Up Next shows a count, which can change while the visible songs don't.
    @Test("the Up Next count changing alone changes Today")
    func countAloneChangesToday() throws {
        let songs = (0..<5).map { capture("Song \($0)", minutesAgo: Double(50 - $0)) }
        try store.context.save()
        let before = try faces()

        songs[4].playedBackAt = now
        try store.context.save()

        #expect(try faces().kindsChanged(since: before) == [WidgetKind.today])
    }

    /// A fetch limit of zero means no limit, and Last Played asks for zero Today rows.
    @Test("asking for no rows of today reads none")
    func zeroLimitReadsNothing() throws {
        capture("First", minutesAgo: 20)
        capture("Second", minutesAgo: 10)
        try store.context.save()

        let reading = try store.widgetReading(todayLimit: 0, upNextLimit: nil, now: now, calendar: calendar)

        #expect(reading.today.isEmpty)
        #expect(reading.lastPlayed?.title == "Second")
        #expect(reading.upNext == nil)
    }

    /// `WidgetRefresher` observes `didSave` with the main context as the object.
    @Test("saving the store's context posts didSave, and an empty save posts nothing")
    func saveIsAnnounced() throws {
        var announced = 0
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: store.context,
            queue: nil
        ) { _ in announced += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        capture("Song", minutesAgo: 1)
        try store.context.save()
        try store.context.save()

        #expect(announced == 1)
    }
}

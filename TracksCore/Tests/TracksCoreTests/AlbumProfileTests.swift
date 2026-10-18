import Testing
import Foundation
@testable import TracksCore

/// A fixed UTC calendar, so results don't depend on the machine's time zone.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func play(
    _ title: String,
    by artist: String = "Mara Solis",
    on album: String? = "Tides",
    id: String = "",
    at when: Date
) -> CaptureStat {
    CaptureStat(
        songKey: title,
        songID: id,
        title: title,
        artistName: artist,
        albumTitle: album,
        capturedAt: when,
        kind: .onDemand
    )
}

/// An album is identified by its title and its artist, because a capture only ever carries
/// the song's catalog id.
private func identity(_ album: String, by artist: String = "Mara Solis") -> String {
    "\(StatsCalculator.folded(album))\u{1F}\(StatsCalculator.folded(artist))"
}

@MainActor
@Suite("Album pages")
struct AlbumProfileTests {
    private let now = date(2026, 9, 15)

    private func history() -> ListeningHistory {
        ListeningHistory([
            play("Saltwater", id: "1", at: date(2026, 8, 1)),
            play("Saltwater", id: "1", at: date(2026, 8, 20)),
            play("Undertow", id: "2", at: date(2026, 9, 2)),
            play("Harbour Light", on: "Glasshouse", id: "3", at: date(2026, 9, 3)),
            play("Northbound", by: "Lossapardo", on: "Compass", id: "4", at: date(2026, 9, 4)),
        ])
    }

    @Test("an album's plays, songs and dates are gathered from its captures")
    func gathersTheAlbum() throws {
        let profile = try #require(
            StatsCalculator.albumProfile(
                id: identity("Tides"), history: history(), calendar: calendar, now: now
            )
        )

        #expect(profile.album.title == "Tides")
        #expect(profile.album.artistName == "Mara Solis")
        #expect(profile.album.count == 3)
        #expect(profile.album.songCount == 2)
        #expect(profile.songs.map(\.title) == ["Saltwater", "Undertow"])
        #expect(profile.firstHeard == date(2026, 8, 1))
        #expect(profile.lastHeard == date(2026, 9, 2))
    }

    @Test("a song with a featured artist counts on its artist's album, from either link")
    func featuredSongsJoinTheAlbum() throws {
        let history = ListeningHistory([
            play("Saltwater", id: "1", at: date(2026, 8, 1)),
            play("Undertow", by: "Mara Solis feat. Yuki Tanabe", id: "2", at: date(2026, 9, 2)),
            play("Riptide", by: "Mara Solis (Feat. Nova Harbor)", id: "3", at: date(2026, 9, 3)),
        ])
        #expect(Set(history.captures.map(\.albumIdentity)) == [identity("Tides")])
        for link in [identity("Tides"), identity("Tides", by: "Mara Solis feat. Yuki Tanabe")] {
            let profile = try #require(StatsCalculator.albumProfile(id: link, history: history, calendar: calendar, now: now))
            #expect(profile.album.artistName == "Mara Solis")
            #expect(profile.album.count == 3)
            #expect(profile.artistID == StatsCalculator.folded("Mara Solis"))
        }
    }

    /// The page links to the artist, so it has to carry an id the artist page understands.
    @Test("the profile carries the artist's identity for the link back")
    func linksToTheArtist() throws {
        let profile = try #require(
            StatsCalculator.albumProfile(
                id: identity("Tides"), history: history(), calendar: calendar, now: now
            )
        )
        #expect(profile.artistID == StatsCalculator.folded("Mara Solis"))
        #expect(StatsCalculator.artistProfile(id: profile.artistID, history: history()) != nil)
    }

    @Test("albums rank against every other album, most played first")
    func ranksAgainstOtherAlbums() throws {
        let subject = history()
        let tides = try #require(
            StatsCalculator.albumProfile(id: identity("Tides"), history: subject, calendar: calendar, now: now)
        )
        let compass = try #require(
            StatsCalculator.albumProfile(
                id: identity("Compass", by: "Lossapardo"), history: subject, calendar: calendar, now: now
            )
        )

        #expect(tides.allTimeRank == 1)
        #expect(compass.allTimeRank > 1)
        // Three of the five plays.
        #expect(tides.share == 0.6)
    }

    /// Two artists can both have a record called "Tides"; they're different pages.
    @Test("albums are kept apart by artist as well as title")
    func separatesSameTitleByArtist() throws {
        let subject = ListeningHistory([
            play("Saltwater", on: "Tides", at: date(2026, 9, 1)),
            play("Ebb", by: "Lossapardo", on: "Tides", at: date(2026, 9, 2)),
            play("Flow", by: "Lossapardo", on: "Tides", at: date(2026, 9, 3)),
        ])

        let mine = try #require(
            StatsCalculator.albumProfile(id: identity("Tides"), history: subject, calendar: calendar, now: now)
        )
        let theirs = try #require(
            StatsCalculator.albumProfile(
                id: identity("Tides", by: "Lossapardo"), history: subject, calendar: calendar, now: now
            )
        )

        #expect(mine.album.count == 1)
        #expect(theirs.album.count == 2)
        #expect(theirs.artistID == StatsCalculator.folded("Lossapardo"))
    }

    @Test("an album that was never played has no page")
    func unknownAlbum() {
        #expect(
            StatsCalculator.albumProfile(
                id: identity("Never Heard"), history: history(), calendar: calendar, now: now
            ) == nil
        )
    }

    /// Songs with no album mustn't collect into one nameless record.
    @Test("songs with no album have no album page")
    func songsWithoutAnAlbum() {
        let subject = ListeningHistory([play("Loose", on: nil, at: date(2026, 9, 1))])
        #expect(StatsCalculator.albumProfile(id: "", history: subject, calendar: calendar, now: now) == nil)
    }

    /// Its songs came out together, so one year reads better than "1994–2011" from an odd
    /// re-release date.
    @Test("the release year is the earliest its songs report")
    func reportsOneReleaseYear() throws {
        let subject = ListeningHistory(
            [
                play("Saltwater", id: "1", at: date(2026, 9, 1)),
                play("Undertow", id: "2", at: date(2026, 9, 2)),
            ],
            songMetadata: [
                HistoryImport.key(title: "Saltwater", artistName: "Mara Solis"):
                    SongMetadata(genre: "Alternative", releaseYear: 1994),
                HistoryImport.key(title: "Undertow", artistName: "Mara Solis"):
                    SongMetadata(genre: "Alternative", releaseYear: 2011),
            ]
        )
        let profile = try #require(
            StatsCalculator.albumProfile(id: identity("Tides"), history: subject, calendar: calendar, now: now)
        )

        #expect(profile.releaseYear == 1994)
        #expect(profile.genre == "Alternative")
    }
}

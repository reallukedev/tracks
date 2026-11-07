import Testing
import Foundation
@testable import TracksCore

@Suite("Tracks Radio through the day")
struct RadioMomentTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A Tuesday at 7 pm.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 19))! }

    func play(_ title: String, by artist: String? = nil, daysAgo: Int, hour: Int) -> CaptureStat {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return CaptureStat(
            songKey: title,
            songID: "id.\(title)",
            title: title,
            artistName: artist ?? "Artist \(title)",
            capturedAt: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        )
    }

    /// Weekday plays: "Evening" songs around 7 pm, "Morning" ones around 8 am, each a few times.
    func habits() -> [CaptureStat] {
        (0..<6).flatMap { index in
            // Tuesdays, a Monday and a Wednesday.
            [7, 8, 13, 14].flatMap { daysAgo in
                [play("Evening \(index)", daysAgo: daysAgo, hour: 19), play("Morning \(index)", daysAgo: daysAgo, hour: 8)]
            }
        }
    }

    func aggregates(_ plays: [CaptureStat]) -> [String: MixBuilder.Aggregate] {
        let songs = MixBuilder.aggregate(ListeningHistory(plays), signals: ListeningSignals(), now: now, calendar: calendar)
        return Dictionary(uniqueKeysWithValues: songs.map { ($0.song.title, $0) })
    }

    // MARK: - The moment

    @Test("a moment reads the hour and the kind of day, only when following the time")
    func moment() {
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 23, minute: 40))!
        #expect(RadioMoment(at: saturday, calendar: calendar, followsTime: true, isDriving: false) == RadioMoment(hour: 23, isWeekend: true))
        #expect(RadioMoment(at: saturday, calendar: calendar, followsTime: false, isDriving: true) == RadioMoment(isDriving: true))
        #expect(RadioMoment(at: saturday, calendar: calendar, followsTime: false, isDriving: false) == .anytime)
        // The next hour is a new moment, so a long listen is made again for it.
        let later = saturday.addingTimeInterval(30 * 60)
        #expect(RadioMoment(at: later, calendar: calendar, followsTime: true, isDriving: false) != RadioMoment(at: saturday, calendar: calendar, followsTime: true, isDriving: false))
    }

    @Test("by default the day is calm late at night and early in the morning, brightest in the afternoon")
    func dayCurve() throws {
        let energies = try (0..<24).map { try #require(RadioMoment(hour: $0).energy) }
        let brightest = try #require(energies.indices.max { energies[$0] < energies[$1] })
        #expect((12...17).contains(brightest))
        #expect(energies[2] < energies[7])
        #expect(energies[7] < energies[15])
        #expect(energies[23] < energies[19])
        #expect(RadioMoment.anytime.energy == nil)
    }

    @Test("the moment's energy follows the day it's given")
    func customDay() throws {
        var day = RadioDay.standard
        day[.lateNight] = .energetic
        let custom = try #require(RadioMoment(hour: 2, day: day).energy)
        let standard = try #require(RadioMoment(hour: 2).energy)
        #expect(custom == RadioDay.Feel.energetic.energy)
        #expect(standard == RadioDay.Feel.calm.energy)
        // The day is part of the moment, so changing it makes the mix again.
        #expect(RadioMoment(hour: 2, day: day) != RadioMoment(hour: 2))
        // Not following the time, the day changes nothing.
        #expect(RadioMoment(isDriving: true, day: day) == RadioMoment(isDriving: true))
    }

    @Test("weekend mornings come round an hour later")
    func weekendMornings() throws {
        let saturdayNine = try #require(RadioMoment(hour: 9, isWeekend: true).energy)
        let tuesdayEight = try #require(RadioMoment(hour: 8).energy)
        #expect(saturdayNine == tuesdayEight)
        #expect(RadioMoment(hour: 20, isWeekend: true).energy == RadioMoment(hour: 20).energy)
    }

    @Test("on the road the energy holds steady, following the hour only halfway")
    func driveEnergy() throws {
        let night = try #require(RadioMoment(hour: 2).energy)
        let nightDrive = try #require(RadioMoment(hour: 2, isDriving: true).energy)
        let afternoonDrive = try #require(RadioMoment(hour: 16, isDriving: true).energy)
        #expect(nightDrive > night)
        #expect(nightDrive < afternoonDrive)
        #expect(RadioMoment(isDriving: true).energy == RadioMoment.driveEnergy)
    }

    @Test("a genre's energy comes from the moods it suits", arguments: [
        ("Ambient", 0.0...0.1),
        ("Jazz", 0.1...0.25),
        ("R&B/Soul", 0.25...0.4),
        ("Rock", 0.6...0.75),
        ("Hip-Hop/Rap", 0.9...1.0),
    ])
    func genreEnergy(genre: String, expected: ClosedRange<Double>) throws {
        let energy = try #require(RadioMoment.energy(ofGenre: genre))
        #expect(expected.contains(energy))
    }

    @Test("a song's energy is the average of its genres that have one")
    func songEnergy() throws {
        let rock = try #require(RadioMoment.energy(ofGenre: "Rock"))
        let jazz = try #require(RadioMoment.energy(ofGenre: "Jazz"))
        #expect(RadioMoment.energy(ofGenres: ["Rock", "Music"]) == rock)
        #expect(RadioMoment.energy(ofGenres: ["Rock", "Jazz", "Country"]) == (rock + jazz) / 2)
        #expect(RadioMoment.energy(ofGenres: ["Music"]) == nil)
        #expect(RadioMoment.energy(ofGenres: []) == nil)
    }

    @Test("a genre no mood speaks for has no energy, and no genre has none either")
    func unknownGenre() {
        #expect(RadioMoment.energy(ofGenre: "Country") == nil)
        #expect(RadioMoment.energy(ofGenre: nil) == nil)
        #expect(RadioMoment.energy(ofGenre: "") == nil)
    }

    // MARK: - Habit

    @Test("songs you play at this hour come up more, and the others less without dropping out")
    func habit() throws {
        let songs = aggregates(habits())
        let fit = RadioMomentFit(moment: RadioMoment(hour: 19), songs: Array(songs.values), drives: DriveLog())
        let evening = fit.factor(for: try #require(songs["Evening 0"]), genre: nil, recentSkips: 0)
        let morning = fit.factor(for: try #require(songs["Morning 0"]), genre: nil, recentSkips: 0)
        #expect(evening > 1.5)
        #expect(morning < 0.7)
        #expect(morning >= 0.4)

        let breakfast = RadioMomentFit(moment: RadioMoment(hour: 8), songs: Array(songs.values), drives: DriveLog())
        #expect(breakfast.factor(for: try #require(songs["Morning 0"]), genre: nil, recentSkips: 0) > 1.5)
    }

    @Test("on a weekend, what you play on weekends comes first, and on weekdays what you play then")
    func kindOfDay() throws {
        // Saturdays at 7 pm.
        let saturdays = (0..<6).flatMap { index in [3, 10, 17, 24].map { play("Saturday \(index)", daysAgo: $0, hour: 19) } }
        let songs = aggregates(habits() + saturdays)
        let weekdayEvening = try #require(songs["Evening 0"])
        let saturdayEvening = try #require(songs["Saturday 0"])
        let weekday = RadioMomentFit(moment: RadioMoment(hour: 19), songs: Array(songs.values), drives: DriveLog())
        let weekend = RadioMomentFit(moment: RadioMoment(hour: 19, isWeekend: true), songs: Array(songs.values), drives: DriveLog())
        #expect(weekday.factor(for: weekdayEvening, genre: nil, recentSkips: 0) > weekday.factor(for: saturdayEvening, genre: nil, recentSkips: 0))
        #expect(weekend.factor(for: saturdayEvening, genre: nil, recentSkips: 0) > weekend.factor(for: weekdayEvening, genre: nil, recentSkips: 0))
    }

    @Test("hours near midnight are near each other")
    func aroundMidnight() {
        let late = RadioMoment(hour: 23)
        #expect(RadioMomentFit.nearness(hourSlot: Int(MixBuilder.Aggregate.hourSlot(0, isWeekend: false)), to: late) == 0.7)
        #expect(RadioMomentFit.nearness(hourSlot: Int(MixBuilder.Aggregate.hourSlot(12, isWeekend: false)), to: late) == 0)
    }

    @Test("not following the time, the hour you play a song at doesn't matter")
    func anytime() throws {
        let songs = aggregates(habits())
        let fit = RadioMomentFit(moment: .anytime, songs: Array(songs.values), drives: DriveLog())
        #expect(fit.factor(for: try #require(songs["Evening 0"]), genre: "Ambient", recentSkips: 0) == 1)
        #expect(fit.factor(for: try #require(songs["Morning 0"]), genre: "Metal", recentSkips: 0) == 1)
        #expect(fit.newShare(0.25) == 0.25)
    }

    @Test("a song skipped lately comes up less at any hour, and less still on the road")
    func skippedLately() throws {
        let songs = aggregates(habits())
        let song = try #require(songs["Evening 0"])
        let anytime = RadioMomentFit(moment: .anytime, songs: Array(songs.values), drives: DriveLog())
        let road = RadioMomentFit(moment: RadioMoment(isDriving: true), songs: Array(songs.values), drives: DriveLog())
        #expect(anytime.factor(for: song, genre: nil, recentSkips: 1) < anytime.factor(for: song, genre: nil, recentSkips: 0))
        let offRoad = anytime.factor(for: song, genre: nil, recentSkips: 1) / anytime.factor(for: song, genre: nil, recentSkips: 0)
        let onRoad = road.factor(for: song, genre: nil, recentSkips: 1) / road.factor(for: song, genre: nil, recentSkips: 0)
        #expect(onRoad < offRoad)
    }

    // MARK: - Energy

    @Test("late at night calm genres come up more, in the afternoon bright ones")
    func energyFollowsTheDay() throws {
        // Heard at the same hours, so only the genre tells them apart.
        let songs = aggregates([play("Calm", daysAgo: 3, hour: 12), play("Loud", daysAgo: 3, hour: 12)])
        let calm = try #require(songs["Calm"])
        let loud = try #require(songs["Loud"])
        let night = RadioMomentFit(moment: RadioMoment(hour: 1), songs: Array(songs.values), drives: DriveLog())
        let afternoon = RadioMomentFit(moment: RadioMoment(hour: 14), songs: Array(songs.values), drives: DriveLog())
        #expect(night.factor(for: calm, genre: "Ambient", recentSkips: 0) > night.factor(for: loud, genre: "Hip-Hop/Rap", recentSkips: 0) * 2)
        // Afternoons are upbeat rather than flat out, so the lean is gentler than the night's.
        #expect(afternoon.factor(for: loud, genre: "Hip-Hop/Rap", recentSkips: 0) > afternoon.factor(for: calm, genre: "Ambient", recentSkips: 0) * 1.5)
        // A song whose genre isn't known is left as it is.
        #expect(night.factor(newFindGenre: nil) == 1)
    }

    // MARK: - Driving

    @Test("on the road, songs you've played while driving come up more")
    func drivePlays() throws {
        let plays = [play("Road", daysAgo: 2, hour: 8), play("Road", daysAgo: 3, hour: 8), play("Home", daysAgo: 2, hour: 20), play("Home", daysAgo: 3, hour: 20)]
        let songs = aggregates(plays)
        let drives = DriveLog(drives: [2, 3].map { daysAgo in
            let start = calendar.date(bySettingHour: 7, minute: 50, second: 0, of: calendar.date(byAdding: .day, value: -daysAgo, to: now)!)!
            return DateInterval(start: start, duration: 30 * 60)
        })
        let fit = RadioMomentFit(moment: RadioMoment(isDriving: true), songs: Array(songs.values), drives: drives)
        let road = fit.factor(for: try #require(songs["Road"]), genre: nil, recentSkips: 0)
        let home = fit.factor(for: try #require(songs["Home"]), genre: nil, recentSkips: 0)
        #expect(road > home * 2)
    }

    @Test("on the road, genres for driving come up more and a recent skip counts against a song")
    func driveGenres() throws {
        let songs = aggregates([play("Song", daysAgo: 2, hour: 12)])
        let song = try #require(songs["Song"])
        let fit = RadioMomentFit(moment: RadioMoment(isDriving: true), songs: [song], drives: DriveLog())
        #expect(fit.factor(for: song, genre: "Alternative", recentSkips: 0) > fit.factor(for: song, genre: "Classical", recentSkips: 0) * 2)
        #expect(fit.factor(for: song, genre: nil, recentSkips: 1) < fit.factor(for: song, genre: nil, recentSkips: 0))
        #expect(fit.factor(newFindGenre: "Rock") > fit.factor(newFindGenre: "Classical"))
    }

    @Test("on the road there are fewer new finds, and the mix knows its moment")
    func driveNewFinds() {
        let finds = (0..<10).map {
            MixSong(songIdentity: "new\($0)", songID: "new\($0)", title: "New \($0)", artistName: "N\($0)", albumTitle: nil, artworkURL: nil, plays: 0, lastHeard: .distantPast)
        }
        let history = ListeningHistory(habits())
        let driving = RadioMoment(hour: 19, isDriving: true)
        let home = LiveMix.tracksRadio(from: history, newFinds: finds, moment: RadioMoment(hour: 19), now: now, calendar: calendar, seed: 1)
        let road = LiveMix.tracksRadio(from: history, newFinds: finds, moment: driving, now: now, calendar: calendar, seed: 1)
        #expect(road.newShare < home.newShare)
        #expect(road.moment == driving)
        #expect(home.moment.isDriving == false)
    }

    // MARK: - The radio

    @Test("in the evening, Tracks Radio opens with evening songs far more often than morning ones")
    func radioFollowsTheHour() {
        let history = ListeningHistory(habits())
        var evening = 0
        var morning = 0
        for seed in 1...200 as ClosedRange<UInt64> {
            var mix = LiveMix.tracksRadio(from: history, moment: RadioMoment(hour: 19), now: now, calendar: calendar, seed: seed)
            for song in (0..<3).compactMap({ _ in mix.next() }) {
                if song.title.hasPrefix("Evening") { evening += 1 } else { morning += 1 }
            }
        }
        #expect(evening > morning * 2)
    }
}

@Suite("Noticing drives")
struct DriveSenseTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    @Test("a sure reading of a car starts a drive; an unsure one doesn't")
    func starts() {
        var sense = DriveSense()
        _ = sense.take(.init(date: at(0), isAutomotive: true, isConfident: false))
        #expect(!sense.isDriving)
        _ = sense.take(.init(date: at(1), isAutomotive: true))
        #expect(sense.isDriving)
        #expect(sense.driveStart == at(1))
    }

    @Test("a stop at the lights doesn't end a drive; a long stop does, at the moment the car stopped")
    func lingers() {
        var sense = DriveSense()
        _ = sense.take(.init(date: at(0), isAutomotive: true))
        #expect(sense.take(.init(date: at(20), isAutomotive: false)) == nil)
        #expect(sense.check(at: at(22)) == nil)
        #expect(sense.isDriving)
        #expect(sense.endsAt == at(20).addingTimeInterval(DriveSense.lingering))
        #expect(sense.check(at: at(25)) == DateInterval(start: at(0), end: at(20)))
        #expect(!sense.isDriving)
    }

    @Test("with the car still sensed, time passing doesn't end the drive")
    func stillInTheCar() {
        var sense = DriveSense()
        _ = sense.take(.init(date: at(0), isAutomotive: true))
        #expect(sense.check(at: at(60)) == nil)
        #expect(sense.endsAt == nil)
    }

    @Test("walking away ends a drive at once")
    func walksAway() {
        var sense = DriveSense()
        _ = sense.take(.init(date: at(0), isAutomotive: true))
        #expect(sense.take(.init(date: at(15), isAutomotive: false, isOnFoot: true)) == DateInterval(start: at(0), end: at(15)))
    }

    @Test("CarPlay is a drive for as long as it's connected")
    func carPlay() {
        var sense = DriveSense()
        _ = sense.carPlay(isConnected: true, at: at(0))
        #expect(sense.isDriving)
        _ = sense.take(.init(date: at(5), isAutomotive: false, isOnFoot: true))
        #expect(sense.check(at: at(60)) == nil)
        #expect(sense.isDriving)
        _ = sense.carPlay(isConnected: false, at: at(70))
        #expect(sense.check(at: at(72)) == nil)
        #expect(sense.check(at: at(75)) == DateInterval(start: at(0), end: at(70)))
    }

    @Test("past readings give their drives, one still under way ending with the readings")
    func history() {
        let readings: [DriveSense.Reading] = [
            .init(date: at(0), isAutomotive: false),
            .init(date: at(10), isAutomotive: true),
            .init(date: at(40), isAutomotive: false, isOnFoot: true),
            .init(date: at(100), isAutomotive: true),
        ]
        #expect(DriveSense.drives(in: readings, until: at(130)) == [
            DateInterval(start: at(10), end: at(40)),
            DateInterval(start: at(100), end: at(130)),
        ])
    }
}

@Suite("The drive log")
struct DriveLogTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    @Test("a play inside a drive was heard driving")
    func contains() {
        let log = DriveLog(drives: [DateInterval(start: at(0), end: at(30)), DateInterval(start: at(100), end: at(130))])
        #expect(log.contains(at(10)))
        #expect(log.contains(at(130)))
        #expect(!log.contains(at(60)))
        #expect(!log.contains(at(-1)))
        #expect(!log.contains(at(200)))
    }

    @Test("drives a stop apart are one, and a very short one isn't kept")
    func joins() {
        var log = DriveLog()
        log.record(DateInterval(start: at(0), end: at(20)), now: at(20))
        log.record(DateInterval(start: at(23), end: at(50)), now: at(50))
        log.record(DateInterval(start: at(90), end: at(91)), now: at(91))
        #expect(log.drives == [DateInterval(start: at(0), end: at(50))])
    }

    @Test("old drives are forgotten")
    func forgets() {
        var log = DriveLog()
        log.record(DateInterval(start: at(0), end: at(30)), now: at(30))
        log.record(DateInterval(start: at(0) + DriveLog.memory + 3_600, duration: 1_800), now: at(0) + DriveLog.memory + 7_200)
        #expect(log.drives.count == 1)
        #expect(!log.contains(at(10)))
    }

    @Test("it's stored and read back, and anything unreadable is an empty log")
    func storage() {
        let log = DriveLog(drives: [DateInterval(start: at(0), end: at(30))])
        #expect(DriveLog(stored: log.stored) == log)
        #expect(DriveLog(stored: Data("nonsense".utf8)).isEmpty)
        #expect(DriveLog(stored: nil).isEmpty)
    }
}

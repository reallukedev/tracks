import Foundation

/// When Tracks Radio is playing, as far as it listens for it: the hour and the kind of day when
/// it follows the time of day, and whether you're driving.
///
/// A mix is made for one moment. When the hour turns or a drive starts or ends, the player
/// makes it again for the new one, keeping what it has already played and learned.
public struct RadioMoment: Sendable, Equatable {
    /// The hour, 0 to 23, when the radio follows the time of day. Nil when it doesn't.
    public var hour: Int?
    public var isWeekend: Bool
    public var isDriving: Bool
    /// The feel of each part of the day, as set under Through the Day. Only asked when the
    /// radio follows the time of day.
    public var day: RadioDay

    public init(hour: Int? = nil, isWeekend: Bool = false, isDriving: Bool = false, day: RadioDay = .standard) {
        self.hour = hour
        self.isWeekend = hour != nil && isWeekend
        self.isDriving = isDriving
        // Not following the time, the day's feels mean nothing, so they never make two
        // moments differ.
        self.day = hour == nil ? .standard : day
    }

    public init(at date: Date, calendar: Calendar = .current, followsTime: Bool, day: RadioDay = .standard, isDriving: Bool) {
        self.init(
            hour: followsTime ? calendar.component(.hour, from: date) : nil,
            isWeekend: calendar.isDateInWeekend(date),
            isDriving: isDriving,
            day: day
        )
    }

    /// Neither the hour nor the road: the radio plays as it's tuned, whenever.
    public static let anytime = RadioMoment()

    public var dayPart: DayPart? { hour.map(DayPart.init(hour:)) }

    // MARK: - Energy

    /// How bright the music should be, from 0, calm, to 1, bright. Nil when nothing asks for
    /// any energy in particular.
    ///
    /// Through the day it follows ``day``, taken at the middle of the hour. On the road it
    /// holds steady, never sleepy and never frantic, and follows the hour only halfway: a
    /// drive at two in the morning is still calmer than one at four in the afternoon.
    public var energy: Double? {
        let day = hour.map { self.day.energy(atHour: Double($0) + 0.5, isWeekend: isWeekend) }
        guard isDriving else { return day }
        return day.map { ($0 + Self.driveEnergy) / 2 } ?? Self.driveEnergy
    }

    static let driveEnergy = 0.65

    /// How bright a genre plays, from 0 to 1, by Apple Music's moods it suits: calm ones (Sleep,
    /// Focus, Chill) pull it down and lively ones (Energy, Workout, Party) push it up. Nil for a
    /// genre that suits none of them, or no genre at all: the history knows a song's genre and
    /// nothing else about its feel.
    public static func energy(ofGenre genre: String?) -> Double? {
        guard let genre, !genre.isEmpty else { return nil }
        let calm = [Mood.sleep, .focus, .chill].count { $0.suits(genre: genre) }
        let bright = [Mood.energy, .workout, .party].count { $0.suits(genre: genre) }
        guard calm + bright > 0 else { return nil }
        return min(1, max(0, 0.5 + Double(bright - calm) / 6))
    }

    /// How bright a song plays, from 0 to 1, by all its genre names (as MusicKit's
    /// `genreNames` lists them): the average of the ones with an energy of their own. Nil
    /// when none of them has one, such as a song listed only under "Music".
    public static func energy(ofGenres genres: [String]) -> Double? {
        let energies = genres.compactMap { energy(ofGenre: $0) }
        guard !energies.isEmpty else { return nil }
        return energies.reduce(0, +) / Double(energies.count)
    }
}

// MARK: - How songs fit

/// How much likelier each song is at a moment, worked out once per mix.
///
/// Three things, multiplied:
/// - Habit: songs you play near this hour on this kind of day (weekday or weekend) come up
///   more, against how much of all your listening falls then. Songs you only play at other
///   times come up less, and never drop out.
/// - Energy: a song's genre against the energy the moment asks for.
/// - The road: songs you've played while driving, songs in genres that suit Apple Music's
///   Driving mood, and songs you know well come up more; songs you skipped lately less, since
///   a skip takes a hand off the wheel. New finds are fewer.
struct RadioMomentFit {
    let moment: RadioMoment
    private let drives: DriveLog
    /// How near each hour and kind of day is to the moment's, by ``MixBuilder/Aggregate/hourSlot(_:isWeekend:)``.
    private let nearness: [Double]
    /// The share of all your listening near the moment: what a song's own share is measured against.
    private let baseline: Double

    /// For counting a song's plays against its recent skips.
    private let now: Date

    init(moment: RadioMoment, songs: [MixBuilder.Aggregate], drives: DriveLog, now: Date = .now) {
        self.moment = moment
        self.drives = drives
        self.now = now
        let nearness = (0..<48).map { slot in Self.nearness(hourSlot: slot, to: moment) }
        self.nearness = nearness
        var near = 0.0
        var total = 0
        if moment.hour != nil {
            for song in songs {
                near += song.hours.reduce(0) { $0 + nearness[Int($1)] }
                total += song.hours.count
            }
        }
        self.baseline = total > 0 ? near / Double(total) : 0
    }

    /// How near one hour and kind of day is to the moment's: in full within the hour, fading
    /// over three hours either side, and less on the other kind of day.
    static func nearness(hourSlot slot: Int, to moment: RadioMoment) -> Double {
        guard let hour = moment.hour else { return 0 }
        let playedHour = slot / 2
        let isWeekend = slot % 2 == 1
        let apart = abs(playedHour - hour)
        let distance = min(apart, 24 - apart)
        let byHour = switch distance {
        case 0: 1.0
        case 1: 0.7
        case 2: 0.35
        case 3: 0.1
        default: 0.0
        }
        return byHour * (isWeekend == moment.isWeekend ? 1 : 0.4)
    }

    /// For a song of yours. A song skipped lately comes up less at any time, and less still
    /// on the road, where a skip takes a hand off the wheel.
    func factor(for song: MixBuilder.Aggregate, genre: String?, recentSkips: Int) -> Double {
        var factor = habit(song) * energy(genre)
        if recentSkips > 0 {
            let recentPlays = song.dates.count { now.timeIntervalSince($0) < ListeningSignals.skipMemory }
            factor *= Self.skipFactor(skips: recentSkips, plays: recentPlays)
        }
        if moment.isDriving {
            factor *= 1 + 0.8 * Double(min(3, drivePlays(song)))
            factor *= roadGenre(genre)
            if song.dates.count >= 3 { factor *= 1.3 }
            if recentSkips > 0 { factor *= 0.65 }
        }
        return factor
    }

    /// What the moment makes stand out about a song: that you've played it on drives, while
    /// driving, or that you play it near this hour far more than your listening overall does.
    func reason(for song: MixBuilder.Aggregate) -> LiveMix.Reason? {
        if moment.isDriving, drivePlays(song) > 0 { return .onTheRoad }
        if moment.hour != nil, song.hours.count >= 3, habit(song) >= Self.aroundNowHabit { return .aroundNow }
        return nil
    }

    /// A skip weighed against the plays around it: one skip of a song you've played a dozen
    /// times lately was the moment, and barely counts; one of a song you never let play counts
    /// in full. From 0.35 to just under 1.
    static func skipFactor(skips: Int, plays: Int) -> Double {
        guard skips > 0 else { return 1 }
        return max(0.35, Double(plays + 1) / (Double(plays + 1) + 1.5 * Double(skips)))
    }

    /// How much likelier the hour makes a song before it's said to be one for around now: well
    /// over half again as likely, from plays enough to go by.
    static let aroundNowHabit = 1.6

    private func drivePlays(_ song: MixBuilder.Aggregate) -> Int {
        song.dates.count { drives.contains($0) }
    }

    /// For a new find, which has no history to go by: its genre only.
    func factor(newFindGenre genre: String?) -> Double {
        energy(genre) * (moment.isDriving ? roadGenre(genre) : 1)
    }

    /// The share of new finds at this moment: fewer on the road, where there's no reaching
    /// for the phone to skip one.
    func newShare(_ share: Double) -> Double {
        moment.isDriving ? share * 0.4 : share
    }

    /// Plays near the moment, against your listening overall, smoothed so a song played once
    /// or twice is judged gently. From 0.4 to 3.
    private func habit(_ song: MixBuilder.Aggregate) -> Double {
        guard baseline > 0.01, !song.hours.isEmpty else { return 1 }
        let near = song.hours.reduce(0) { $0 + nearness[Int($1)] }
        let smoothing = 2.0
        let share = (near + smoothing * baseline) / (Double(song.hours.count) + smoothing)
        return min(3, max(0.4, share / baseline))
    }

    /// From 0.35 for a genre at the far end of the energy asked for, to 1.65 for one right on it.
    private func energy(_ genre: String?) -> Double {
        guard let wanted = moment.energy, let energy = RadioMoment.energy(ofGenre: genre) else { return 1 }
        let fit = 1 - abs(energy - wanted)
        return 0.35 + 1.3 * fit * fit
    }

    private func roadGenre(_ genre: String?) -> Double {
        guard let genre, !genre.isEmpty else { return 1 }
        return Mood.drive.suits(genre: genre) ? 1.8 : 0.75
    }
}

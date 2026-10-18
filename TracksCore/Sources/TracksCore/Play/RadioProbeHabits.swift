import Foundation

/// What has landed on Tracks Radio before, so the next listen starts from it: for each part of
/// the day and for drives, how often songs in each genre family, from each decade, and new
/// finds were let play or skipped.
///
/// Only genre families, decades and counts: never a song or an artist, so it says nothing
/// about what was played when. Kept on this device. Old listens fade with ``halfLife``, so a
/// habit that has changed stops steering the radio after a few weeks.
public struct RadioHabits: Codable, Sendable, Equatable {
    /// When a listen was: the part of the day, a drive, or anytime for a radio that doesn't
    /// follow the time of day.
    public enum Band: String, Codable, Sendable, CaseIterable {
        case morning, afternoon, evening, night, drive, anytime

        public init(moment: RadioMoment) {
            if moment.isDriving {
                self = .drive
                return
            }
            switch moment.dayPart {
            case .morning: self = .morning
            case .afternoon: self = .afternoon
            case .evening: self = .evening
            case .night: self = .night
            case nil: self = .anytime
            }
        }
    }

    /// Songs let play and songs that didn't land, faded with time, so not whole numbers.
    public struct Tally: Codable, Sendable, Equatable {
        public var landed: Double = 0
        public var missed: Double = 0

        public var total: Double { landed + missed }

        /// Kept to ``RadioHabits/mostHeard`` at most, in proportion, so a lot of old listening
        /// can still be outweighed by a few new listens.
        mutating func add(landed: Double, missed: Double) {
            self.landed += landed
            self.missed += missed
            if total > RadioHabits.mostHeard {
                let scale = RadioHabits.mostHeard / total
                self.landed *= scale
                self.missed *= scale
            }
        }

        func scaled(_ factor: Double) -> Tally {
            Tally(landed: landed * factor, missed: missed * factor)
        }

        static func + (lhs: Tally, rhs: Tally) -> Tally {
            Tally(landed: lhs.landed + rhs.landed, missed: lhs.missed + rhs.missed)
        }
    }

    struct BandHabits: Codable, Sendable, Equatable {
        var genres: [String: Tally] = [:]
        /// By the decade's first year, as text so it stores as an object.
        var decades: [String: Tally] = [:]
        var newFinds = Tally()

        var total: Double { genres.values.reduce(0) { $0 + $1.total } }
    }

    /// By ``Band`` raw value.
    var bands: [String: BandHabits] = [:]
    /// Every song heard on Tracks Radio, let play or not, at any moment: how readily this
    /// person skips, so a skip from someone who seldom does counts for more. Nil in habits kept
    /// before it was, which read as nothing heard.
    var listening: Tally?
    /// When it was last brought up to date, for fading it.
    public private(set) var updated: Date?

    /// How long it takes what a listen taught to count half as much.
    public static let halfLife: TimeInterval = 45 * 24 * 60 * 60
    /// The most songs a tally counts, so no habit becomes certain.
    static let mostHeard = 20.0
    /// How much the other parts of the day count toward one with little to go by: evenings
    /// tell something about mornings, but not much.
    static let elsewhere = 0.25

    public init() {}

    public var isEmpty: Bool { bands.isEmpty }

    /// A genre family's tally at a moment, with the other moments' counted for a little.
    /// - Parameter genre: as ``LiveMix`` folds it: "hip-hop" for "Hip-Hop/Rap".
    public func tally(genre: String, in band: Band) -> Tally {
        pooled(band) { $0.genres[genre] }
    }

    func tally(decade: Int, in band: Band) -> Tally {
        pooled(band) { $0.decades[String(decade)] }
    }

    func tallyOfNewFinds(in band: Band) -> Tally {
        pooled(band) { $0.newFinds }
    }

    /// Everything heard at that moment itself.
    func heard(in band: Band) -> Double {
        bands[band.rawValue]?.total ?? 0
    }

    private func pooled(_ band: Band, _ tally: (BandHabits) -> Tally?) -> Tally {
        var sum = Tally()
        for (key, habits) in bands {
            guard let found = tally(habits) else { continue }
            sum = sum + found.scaled(key == band.rawValue ? 1 : Self.elsewhere)
        }
        return sum
    }

    /// A song that landed or didn't, by what it was. `landed` and `missed` are how much it
    /// counts: more for a song in the opening probe.
    mutating func record(landed: Double, missed: Double, genre: String?, decade: Int?, isNew: Bool, in band: Band) {
        var habits = bands[band.rawValue] ?? BandHabits()
        if let genre { habits.genres[genre, default: Tally()].add(landed: landed, missed: missed) }
        if let decade { habits.decades[String(decade), default: Tally()].add(landed: landed, missed: missed) }
        if isNew { habits.newFinds.add(landed: landed, missed: missed) }
        bands[band.rawValue] = habits
    }

    /// A song heard, let play or not, for ``listening``.
    mutating func recordListen(landed: Bool) {
        var tally = listening ?? Tally()
        tally.add(landed: landed ? 1 : 0, missed: landed ? 0 : 1)
        listening = tally
    }

    /// These habits with what another listen added, capped as each tally is.
    func adding(_ other: RadioHabits) -> RadioHabits {
        var sum = self
        if let theirs = other.listening {
            var tally = sum.listening ?? Tally()
            tally.add(landed: theirs.landed, missed: theirs.missed)
            sum.listening = tally
        }
        for (key, theirs) in other.bands {
            var habits = sum.bands[key] ?? BandHabits()
            for (genre, tally) in theirs.genres { habits.genres[genre, default: Tally()].add(landed: tally.landed, missed: tally.missed) }
            for (decade, tally) in theirs.decades { habits.decades[decade, default: Tally()].add(landed: tally.landed, missed: tally.missed) }
            habits.newFinds.add(landed: theirs.newFinds.landed, missed: theirs.newFinds.missed)
            sum.bands[key] = habits
        }
        return sum
    }

    /// Faded to `now`, halving every ``halfLife`` since it was last brought up to date, and
    /// dated `now`. Tallies faded to almost nothing are let go.
    public func decayed(to now: Date) -> RadioHabits {
        var faded = self
        faded.updated = now
        guard let updated, now > updated else { return faded }
        let factor = pow(0.5, now.timeIntervalSince(updated) / Self.halfLife)
        faded.listening = listening?.scaled(factor)
        faded.bands = bands.compactMapValues { habits in
            var habits = habits
            habits.genres = habits.genres.mapValues { $0.scaled(factor) }.filter { $0.value.total >= Self.forgotten }
            habits.decades = habits.decades.mapValues { $0.scaled(factor) }.filter { $0.value.total >= Self.forgotten }
            habits.newFinds = habits.newFinds.scaled(factor)
            return habits.genres.isEmpty && habits.decades.isEmpty && habits.newFinds.total < Self.forgotten ? nil : habits
        }
        return faded
    }

    private static let forgotten = 0.05

    // MARK: - Storage

    /// As JSON, for a defaults key.
    public var stored: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    /// Anything unreadable is a radio with nothing learned yet.
    public init(stored: String) {
        self = (try? JSONDecoder().decode(RadioHabits.self, from: Data(stored.utf8))) ?? RadioHabits()
    }
}

import Foundation

/// How Tracks Radio feels through the day: one feel for each part of it, from Calm to
/// Energetic. The person's to set, under Follow the Time of Day.
///
/// The standard day is relaxing at night, gentle in the morning, brightest in the afternoon,
/// and eases back through the evening. Each part plays its feel, and the radio eases from one
/// to the next over the hour either side of the change.
public struct RadioDay: Codable, Sendable, Equatable {
    /// A part of the day, in the order the day runs from early morning.
    public enum Part: String, Codable, Sendable, CaseIterable, Identifiable {
        case earlyMorning
        case morning
        case afternoon
        case evening
        case night
        case lateNight

        public var id: String { rawValue }

        /// The hour the part starts. Weekend mornings come round an hour later, so the parts
        /// from early morning to the afternoon start an hour later on a weekend.
        public func startHour(isWeekend: Bool = false) -> Int {
            let late = isWeekend ? 1 : 0
            return switch self {
            case .earlyMorning: 5 + late
            case .morning: 8 + late
            case .afternoon: 12 + late
            case .evening: 17
            case .night: 21
            case .lateNight: 0
            }
        }

        /// The hour the part ends, exclusive: 24 for the night, which runs to midnight.
        public func endHour(isWeekend: Bool = false) -> Int {
            self == .night ? 24 : next.startHour(isWeekend: isWeekend)
        }

        /// The part the hour falls in, from 0 to 23.
        public init(hour: Int, isWeekend: Bool = false) {
            let hour = ((hour % 24) + 24) % 24
            self = Self.allCases
                .filter { $0.startHour(isWeekend: isWeekend) <= hour }
                .max { $0.startHour(isWeekend: isWeekend) < $1.startHour(isWeekend: isWeekend) } ?? .lateNight
        }

        /// The part after this one, round the clock.
        var next: Part {
            let parts = Self.allCases
            return parts[(parts.firstIndex(of: self)! + 1) % parts.count]
        }
    }

    /// How bright the music is in a part of the day.
    public enum Feel: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
        case calm
        case easy
        case balanced
        case upbeat
        case energetic

        public var id: String { rawValue }

        /// From 0, calm, to 1, bright, on the scale of ``RadioMoment/energy(ofGenre:)``.
        public var energy: Double {
            switch self {
            case .calm: 0.1
            case .easy: 0.3
            case .balanced: 0.5
            case .upbeat: 0.7
            case .energetic: 0.9
            }
        }

        public static func < (lhs: Feel, rhs: Feel) -> Bool { lhs.energy < rhs.energy }
    }

    /// The feels chosen. A part left out plays its standard feel, so a day stored before a
    /// part existed still reads.
    private var feels: [Part: Feel]

    public init(_ feels: [Part: Feel] = [:]) {
        self.feels = feels
    }

    /// Relaxing at night, gentle mornings, brighter afternoons, easing through the evening.
    public static let standard = RadioDay()

    public static func standardFeel(for part: Part) -> Feel {
        switch part {
        case .earlyMorning: .easy
        case .morning: .balanced
        case .afternoon: .upbeat
        case .evening: .balanced
        case .night, .lateNight: .calm
        }
    }

    public subscript(part: Part) -> Feel {
        get { feels[part] ?? Self.standardFeel(for: part) }
        set { feels[part] = newValue == Self.standardFeel(for: part) ? nil : newValue }
    }

    /// Whether every part plays its standard feel.
    public var isStandard: Bool {
        Part.allCases.allSatisfy { self[$0] == Self.standardFeel(for: $0) }
    }

    /// The first part of the day, from early morning, playing the calmest feel.
    public var calmest: Part {
        Part.allCases.min { self[$0] < self[$1] } ?? .night
    }

    /// The first part of the day, from early morning, playing the brightest feel.
    public var brightest: Part {
        Part.allCases.max { self[$0] < self[$1] } ?? .afternoon
    }

    /// Whether every part plays the same feel, so the day has no shape at all.
    public var isFlat: Bool { self[calmest] == self[brightest] }

    // MARK: - The curve

    /// How bright the music is at a time of day, from 0 to 1.
    /// - Parameter hour: hours since midnight, 0 up to 24, with the minutes as a fraction.
    ///
    /// A part's own feel holds from an hour after it starts to an hour before it ends, and the
    /// two hours around each change ease from one feel to the next, so the radio never lurches
    /// as the clock turns.
    public func energy(atHour hour: Double, isWeekend: Bool = false) -> Double {
        let hour = hour.truncatingRemainder(dividingBy: 24) + (hour < 0 ? 24 : 0)
        for part in Part.allCases {
            let change = Double(part.startHour(isWeekend: isWeekend))
            // How far past the change, round the clock, from -12 to 12.
            var offset = hour - change
            if offset > 12 { offset -= 24 }
            if offset < -12 { offset += 24 }
            guard abs(offset) < Self.easing else { continue }
            let before = self[Part(hour: part.startHour(isWeekend: isWeekend) - 1, isWeekend: isWeekend)].energy
            let after = self[part].energy
            let progress = (offset + Self.easing) / (2 * Self.easing)
            // Smoothstep: leaves one feel and arrives at the next without a corner.
            let eased = progress * progress * (3 - 2 * progress)
            return before + (after - before) * eased
        }
        return self[Part(hour: Int(hour), isWeekend: isWeekend)].energy
    }

    /// Hours either side of a change over which one feel eases into the next. Every part is at
    /// least three hours long, so two changes never overlap.
    static let easing = 1.0

    // MARK: - Storage

    /// As JSON, for a defaults key. Anything unreadable is the standard day.
    public var stored: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    public init(stored: String) {
        self = stored.data(using: .utf8).flatMap { try? JSONDecoder().decode(RadioDay.self, from: $0) } ?? .standard
    }

    private enum CodingKeys: String, CodingKey {
        case feels
    }

    /// Reads the parts it knows and skips any it doesn't, so a day saved by a newer version
    /// still reads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: String].self, forKey: .feels) ?? [:]
        var feels: [Part: Feel] = [:]
        for (part, feel) in raw {
            if let part = Part(rawValue: part), let feel = Feel(rawValue: feel) { feels[part] = feel }
        }
        self.feels = feels
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: feels.map { ($0.key.rawValue, $0.value.rawValue) }), forKey: .feels)
    }
}

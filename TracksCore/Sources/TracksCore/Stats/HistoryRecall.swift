import Foundation

/// A history search read for what people remember about a song when its name escapes them:
/// when they heard it ("last tuesday evening", "in march", "last summer"), where ("on the
/// radio", a station's name), its era ("90s"), its feel ("something chill"), what played around
/// it ("after driftwood"), and whether it was played a lot. Whatever isn't one of those is left
/// as words to match, as a plain search would.
///
/// English phrases only, as the rest of search's wording is.
public struct HistoryRecall: Sendable, Equatable {
    /// What ``interval`` covers, so it can be named.
    public enum Span: Sendable, Equatable {
        case day
        /// An evening and the small hours after it.
        case night
        case weekend, week, month, year
        case season(Season)
    }

    public enum Season: String, Sendable, Equatable, CaseIterable {
        case spring, summer, autumn, winter
    }

    public enum PartOfDay: String, Sendable, Equatable, CaseIterable {
        case morning, afternoon, evening, night

        /// Whether a play at `hour` belongs to this part of the day.
        func contains(hour: Int) -> Bool {
            switch self {
            case .morning: (5..<12).contains(hour)
            case .afternoon: (12..<17).contains(hour)
            case .evening: (17..<22).contains(hour)
            case .night: hour >= 22 || hour < 5
            }
        }
    }

    public enum Relation: Sendable, Equatable {
        /// The songs that played right after one, found by the words of its name.
        case after(String)
        case before(String)

        public var anchor: String {
            switch self {
            case .after(let text), .before(let text): text
            }
        }
    }

    /// Folded words left to match against a song, its artist, album, genre and station.
    public internal(set) var words: [String] = []
    /// When the plays were, if a time was named.
    public internal(set) var interval: DateInterval?
    public internal(set) var span: Span?
    public internal(set) var partOfDay: PartOfDay?
    /// 1 for Sunday, as `Calendar` counts, for "tuesdays".
    public internal(set) var weekday: Int?
    public internal(set) var radioOnly = false
    /// A station's name as the history has it.
    public internal(set) var station: String?
    /// The first year of a decade songs came out in, like 1990.
    public internal(set) var decade: Int?
    public internal(set) var relation: Relation?
    /// A feel, read from the song's genre, which is all the history knows of how it sounds.
    public internal(set) var mood: Mood?
    /// "played a lot", "on repeat": the most played first even for a single day.
    public internal(set) var prefersMostPlayed = false

    /// Whether anything was understood beyond words to match.
    public var hasFilters: Bool {
        interval != nil || partOfDay != nil || weekday != nil || radioOnly || station != nil
            || decade != nil || relation != nil || mood != nil
    }

    /// Whether the plays' times matter, so plays whose time isn't known are left out.
    var needsKnownTime: Bool {
        interval != nil || partOfDay != nil || weekday != nil || relation != nil
    }

    /// Whether the part of the day still needs checking play by play: a day's interval is
    /// already cut to it.
    var checksPartOfDay: Bool {
        partOfDay != nil && span != .day && span != .night
    }

    /// The same with its most particular clue let go: the words, then the feel, the era, then
    /// the station, keeping when and around what. Nil when there's nothing left to let go of
    /// or nothing would be left to search by.
    public func loosened() -> HistoryRecall? {
        var looser = self
        if !words.isEmpty {
            looser.words = []
        } else if mood != nil {
            looser.mood = nil
        } else if decade != nil {
            looser.decade = nil
        } else if station != nil || radioOnly {
            looser.station = nil
            looser.radioOnly = false
        } else {
            return nil
        }
        return looser.hasFilters ? looser : nil
    }

    /// Reads `text`. `stations` are the station names in the history, so one can be named.
    public static func parse(
        _ text: String,
        stations: [String] = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> HistoryRecall {
        var reader = RecallReader(
            tokens: SearchFolding.fold(text).split(separator: " ").map(String.init),
            stations: stations
                .map { (name: $0, tokens: SearchFolding.fold($0).split(separator: " ").map(String.init)) }
                .filter { !$0.tokens.isEmpty }
                // The longest first, so "late night jazz radio" isn't read as "late night".
                .sorted { $0.tokens.count > $1.tokens.count },
            now: now,
            calendar: calendar
        )
        return reader.read()
    }
}

// MARK: - Reading

private struct RecallReader {
    let tokens: [String]
    let stations: [(name: String, tokens: [String])]
    let now: Date
    let calendar: Calendar
    var recall = HistoryRecall()
    var index = 0

    mutating func read() -> HistoryRecall {
        var left: [String] = []
        while index < tokens.count {
            if readStation() || readRadio() || readTime() || readPartOfDay() || readDecade() {
                continue
            }
            left.append(tokens[index])
            index += 1
        }
        readRelation(&left)
        readMood(&left)
        // Only once something was understood: "the" in a plain search is part of a name.
        if recall.hasFilters {
            readRepeats(&left)
            recall.words = left.filter { !Self.filler.contains($0) }
        } else {
            recall.words = left
        }
        return recall
    }

    /// Words that only join a remembered phrase together.
    static let filler: Set<String> = [
        "a", "at", "during", "every", "from", "heard", "i", "in", "it", "listened", "listening", "lot", "of",
        "on", "one", "played", "playing", "song", "songs", "that", "the", "to", "track", "tracks",
        "was", "what", "when", "which", "something", "stuff", "music", "tune", "tunes", "vibe", "vibes",
        "mood", "kind", "sort", "some", "with", "by", "me", "my", "kept",
    ]

    private func token(_ offset: Int = 0) -> String? {
        let at = index + offset
        return tokens.indices.contains(at) ? tokens[at] : nil
    }

    private func matches(_ words: [String]) -> Bool {
        words.indices.allSatisfy { token($0) == words[$0] }
    }

    /// Whether the word before says a time follows: "in may", "at night", "the summer".
    private var hasContextBefore: Bool {
        index > 0 && ["at", "during", "every", "in", "of", "the"].contains(tokens[index - 1])
    }

    // MARK: Where

    private mutating func readStation() -> Bool {
        guard recall.station == nil else { return false }
        for station in stations where matches(station.tokens) {
            recall.station = station.name
            index += station.tokens.count
            return true
        }
        return false
    }

    private mutating func readRadio() -> Bool {
        guard token() == "radio" else { return false }
        recall.radioOnly = true
        index += 1
        return true
    }

    // MARK: When

    private mutating func readTime() -> Bool {
        guard recall.interval == nil, recall.weekday == nil, let first = token() else { return false }
        let second = token(1)
        let today = calendar.startOfDay(for: now)
        let yesterday = StatsCalculator.dayBefore(today, calendar: calendar)

        switch first {
        case "today":
            return setDay(today, consumed: 1)
        case "tonight":
            return setNight(of: today, consumed: 1)
        case "yesterday":
            if second == "night" { return setNight(of: yesterday, consumed: 2) }
            return setDay(yesterday, consumed: 1)
        case "last" where second == "night":
            return setNight(of: yesterday, consumed: 2)
        case "this" where second.flatMap(HistoryRecall.PartOfDay.init(rawValue:)) != nil:
            return setDay(today, consumed: 1)
        case "this", "last":
            guard let second else { return false }
            let back = first == "last" ? 1 : 0
            if let unit = Self.units[second] {
                return setUnit(unit, back: back, consumed: 2)
            }
            if let weekday = Self.weekday(named: second), Self.weekdayNames.contains(second) {
                return setWeekday(weekday, allowsToday: back == 0, consumed: 2)
            }
            if let month = Self.month(named: second) {
                return setMonth(month, year: nil, allowsCurrent: back == 0, consumed: 2)
            }
            if let season = HistoryRecall.Season(named: second) {
                return setSeason(season, allowsCurrent: back == 0, consumed: 2)
            }
            return false
        default:
            break
        }

        // "3 days ago", "a week ago", "two weekends ago".
        if let count = Self.number(first), let second, token(2) == "ago",
           let unit = Self.units[second.hasSuffix("s") ? String(second.dropLast()) : second] {
            return setUnit(unit, back: count, consumed: 3)
        }
        if let weekday = Self.weekday(named: first) {
            if !Self.weekdayNames.contains(first) {
                // "tuesdays": any Tuesday.
                recall.weekday = weekday
                index += 1
                return true
            }
            return setWeekday(weekday, allowsToday: true, consumed: 1)
        }
        let yearAfter = second.flatMap(year)
        if let month = Self.month(named: first) {
            // "may" and "march" are words too, so on their own they need "in" before them or
            // a year after.
            guard !Self.ambiguousMonths.contains(first) || hasContextBefore || yearAfter != nil else { return false }
            return setMonth(month, year: yearAfter, allowsCurrent: true, consumed: yearAfter == nil ? 1 : 2)
        }
        if let season = HistoryRecall.Season(named: first), hasContextBefore || yearAfter != nil {
            if let yearAfter {
                return setSeason(season, startingIn: yearAfter, consumed: 2)
            }
            return setSeason(season, allowsCurrent: true, consumed: 1)
        }
        if let year = year(first) {
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let interval = calendar.dateInterval(of: .year, for: start) else { return false }
            return set(interval, span: .year, consumed: 1)
        }
        return false
    }

    private mutating func readPartOfDay() -> Bool {
        guard recall.partOfDay == nil, let first = token() else { return false }
        if first == "late", token(1) == "nights" || token(1) == "night" || (token(1) == "at" && token(2) == "night") {
            index += token(1) == "at" ? 3 : 2
            return setPartOfDay(.night)
        }
        let isPlural = first.hasSuffix("s")
        guard let part = HistoryRecall.PartOfDay(rawValue: isPlural ? String(first.dropLast()) : first) else {
            return false
        }
        // "Night Drive" is a song; "at night", "evenings" and "tuesday night" are times.
        guard isPlural || hasContextBefore || recall.interval != nil || recall.weekday != nil else { return false }
        index += 1
        return setPartOfDay(part)
    }

    private mutating func setPartOfDay(_ part: HistoryRecall.PartOfDay) -> Bool {
        recall.partOfDay = part
        // "tuesday, in the evening": the day narrows to the evening.
        if recall.span == .day, let day = recall.interval?.start {
            narrow(day: calendar.startOfDay(for: day), to: part)
        }
        return true
    }

    private mutating func setDay(_ day: Date, consumed: Int) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        _ = set(interval, span: .day, consumed: consumed)
        // "this evening", "yesterday morning", or a part of the day named before the day.
        if let part = token().flatMap(HistoryRecall.PartOfDay.init(rawValue:)) {
            index += 1
            recall.partOfDay = part
        }
        if let part = recall.partOfDay {
            narrow(day: day, to: part)
        }
        return true
    }

    private mutating func setNight(of day: Date, consumed: Int) -> Bool {
        guard let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
              let end = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: nextDay) else { return false }
        recall.partOfDay = nil
        return set(DateInterval(start: start, end: end), span: .night, consumed: consumed)
    }

    /// The day's interval cut to a part of it. A night runs on into the next morning.
    private mutating func narrow(day: Date, to part: HistoryRecall.PartOfDay) {
        if part == .night {
            _ = setNight(of: day, consumed: 0)
            return
        }
        let hours = switch part {
        case .morning: (5, 12)
        case .afternoon: (12, 17)
        default: (17, 22)
        }
        guard let start = calendar.date(bySettingHour: hours.0, minute: 0, second: 0, of: day),
              let end = calendar.date(bySettingHour: hours.1, minute: 0, second: 0, of: day) else { return }
        recall.interval = DateInterval(start: start, end: end)
    }

    /// A calendar unit `back` of them before now; nil for a weekend.
    private mutating func setUnit(_ unit: Calendar.Component?, back: Int, consumed: Int) -> Bool {
        guard let unit else { return setWeekend(back: back, consumed: consumed) }
        guard let reference = calendar.date(byAdding: unit, value: -back, to: now),
              let interval = calendar.dateInterval(of: unit, for: reference) else { return false }
        switch unit {
        case .day: return setDay(interval.start, consumed: consumed)
        case .weekOfYear: return set(interval, span: .week, consumed: consumed)
        case .month: return set(interval, span: .month, consumed: consumed)
        default: return set(interval, span: .year, consumed: consumed)
        }
    }

    /// The weekend going on or the last one, then `back` more before it. On a Sunday, "last
    /// weekend" is the one before this.
    private mutating func setWeekend(back: Int, consumed: Int) -> Bool {
        var cursor = calendar.startOfDay(for: now)
        while !calendar.isDateInWeekend(cursor) {
            cursor = StatsCalculator.dayBefore(cursor, calendar: calendar)
        }
        guard var weekend = calendar.dateIntervalOfWeekend(containing: cursor) else { return false }
        // A weekday after a weekend: that weekend is "last weekend", and "this weekend" too.
        let isOn = calendar.isDateInWeekend(now)
        for _ in 0..<(isOn ? back : max(0, back - 1)) {
            guard let previous = calendar.nextWeekend(startingAfter: weekend.start, direction: .backward) else {
                return false
            }
            weekend = previous
        }
        return set(weekend, span: .weekend, consumed: consumed)
    }

    private mutating func setWeekday(_ weekday: Int, allowsToday: Bool, consumed: Int) -> Bool {
        var day = calendar.startOfDay(for: now)
        if !allowsToday { day = StatsCalculator.dayBefore(day, calendar: calendar) }
        while calendar.component(.weekday, from: day) != weekday {
            day = StatsCalculator.dayBefore(day, calendar: calendar)
        }
        if token(consumed) == "night" {
            return setNight(of: day, consumed: consumed + 1)
        }
        return setDay(day, consumed: consumed)
    }

    private mutating func setMonth(_ month: Int, year: Int?, allowsCurrent: Bool, consumed: Int) -> Bool {
        let current = calendar.dateComponents([.year, .month], from: now)
        var target = year ?? current.year ?? 2000
        if year == nil, let thisMonth = current.month, month > thisMonth || (month == thisMonth && !allowsCurrent) {
            target -= 1
        }
        guard let start = calendar.date(from: DateComponents(year: target, month: month, day: 1)),
              let interval = calendar.dateInterval(of: .month, for: start) else { return false }
        return set(interval, span: .month, consumed: consumed)
    }

    private mutating func setSeason(_ season: HistoryRecall.Season, allowsCurrent: Bool, consumed: Int) -> Bool {
        let firstMonth = season.firstMonth(southern: Self.isSouthern(calendar))
        let current = calendar.dateComponents([.year, .month], from: now)
        guard let year = current.year, let month = current.month else { return false }
        var startYear = month >= firstMonth ? year : year - 1
        // It's on now, and "last summer" means the one before.
        let isOn = (month - firstMonth + 12) % 12 < 3
        if isOn && !allowsCurrent { startYear -= 1 }
        return setSeason(season, startingIn: startYear, consumed: consumed)
    }

    private mutating func setSeason(_ season: HistoryRecall.Season, startingIn year: Int, consumed: Int) -> Bool {
        let firstMonth = season.firstMonth(southern: Self.isSouthern(calendar))
        guard let start = calendar.date(from: DateComponents(year: year, month: firstMonth, day: 1)),
              let end = calendar.date(byAdding: .month, value: 3, to: start) else { return false }
        return set(DateInterval(start: start, end: end), span: .season(season), consumed: consumed)
    }

    private mutating func set(_ interval: DateInterval, span: HistoryRecall.Span, consumed: Int) -> Bool {
        recall.interval = interval
        recall.span = span
        index += consumed
        return true
    }

    // MARK: Era

    private mutating func readDecade() -> Bool {
        guard recall.decade == nil, let first = token(), first.hasSuffix("s") else { return false }
        let digits = first.dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let value = Int(digits), value % 10 == 0 else { return false }
        switch digits.count {
        case 2: recall.decade = value >= 30 ? 1900 + value : 2000 + value
        case 4 where (1900...2090).contains(value): recall.decade = value
        default: return false
        }
        index += 1
        return true
    }

    // MARK: Around

    /// "after driftwood": the words after it name the song.
    private mutating func readRelation(_ left: inout [String]) {
        guard let start = left.firstIndex(where: { $0 == "after" || $0 == "before" }) else { return }
        let anchor = left[(start + 1)...].filter { !Self.filler.contains($0) }
        guard !anchor.isEmpty else { return }
        let text = anchor.joined(separator: " ")
        recall.relation = left[start] == "after" ? .after(text) : .before(text)
        left = Array(left[..<start])
    }

    // MARK: Feel

    /// "something chill", "sad songs", or a feel beside a time ("upbeat last summer"). On its own,
    /// a feel word is more likely part of a name: "Happy" is a song.
    private mutating func readMood(_ left: inout [String]) {
        let hasContext = recall.hasFilters || left.contains { Self.moodContext.contains($0) }
        guard hasContext else { return }
        // With the radio named, a station's own words name it: "chill radio" is Chill Station.
        let stationWords = recall.radioOnly ? Set(stations.flatMap(\.tokens)) : []
        for (offset, word) in left.enumerated() where !stationWords.contains(word) {
            let pair = left.indices.contains(offset + 1) ? "\(word) \(left[offset + 1])" : nil
            if let pair, let mood = Self.moods[pair] {
                recall.mood = mood
                left.removeSubrange(offset...(offset + 1))
                return
            }
            if let mood = Self.moods[word] {
                recall.mood = mood
                left.remove(at: offset)
                return
            }
        }
    }

    private static let moodContext: Set<String> = ["song", "songs", "music", "something", "stuff", "tunes", "vibes", "track", "tracks"]

    private static let moods: [String: Mood] = {
        let words: [Mood: [String]] = [
            .chill: ["chill", "chilled", "mellow", "calm", "relaxing", "relaxed", "soft", "quiet", "cozy", "slow", "laid back"],
            .heartbreak: ["sad", "melancholy", "heartbreak", "heartbroken", "breakup", "break up", "crying", "moody"],
            .feelGood: ["happy", "upbeat", "cheerful", "sunny", "feelgood", "feel good", "uplifting"],
            .energy: ["energetic", "hype", "hyped", "intense", "heavy", "loud", "pumped", "fast"],
            .workout: ["workout", "gym", "running"],
            .party: ["party", "partying", "danceable"],
            .love: ["romantic", "love songs"],
            .focus: ["focus", "study", "studying", "instrumental"],
            .sleep: ["sleep", "sleepy"],
            .drive: ["driving", "road trip"],
        ]
        var map: [String: Mood] = [:]
        for (mood, list) in words { for word in list { map[word] = mood } }
        return map
    }()

    // MARK: How often

    /// "a lot", "on repeat", "over and over": what was played most, rather than when.
    private mutating func readRepeats(_ left: inout [String]) {
        var kept: [String] = []
        var index = 0
        while index < left.count {
            let word = left[index]
            let next = left.indices.contains(index + 1) ? left[index + 1] : nil
            if word == "a", next == "lot" {
                recall.prefersMostPlayed = true
                index += 2
            } else if word == "over", next == "and", left.indices.contains(index + 2), left[index + 2] == "over" {
                recall.prefersMostPlayed = true
                index += 3
            } else if ["lots", "loads", "repeat", "most", "constantly", "nonstop"].contains(word) {
                recall.prefersMostPlayed = true
                index += 1
            } else {
                kept.append(word)
                index += 1
            }
        }
        left = kept
    }

    // MARK: Words

    /// Nil for a weekend, which isn't a calendar unit.
    private static let units: [String: Calendar.Component?] = [
        "day": .day, "week": .weekOfYear, "weekend": nil, "month": .month, "year": .year,
    ]

    private static func number(_ word: String) -> Int? {
        if let value = Int(word), (1...60).contains(value) { return value }
        let words = [
            "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        ]
        return words[word]
    }

    private static let englishCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    private static let weekdayNames = englishCalendar.weekdaySymbols.map { $0.lowercased() }

    /// A weekday by its name, or its plural, 1 for Sunday.
    private static func weekday(named word: String) -> Int? {
        let name = weekdayNames.contains(word) || !word.hasSuffix("s") ? word : String(word.dropLast())
        return weekdayNames.firstIndex(of: name).map { $0 + 1 }
    }

    private static let monthNames = englishCalendar.monthSymbols.map { $0.lowercased() }
    private static let shortMonths = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sept", "oct", "nov", "dec"]
    private static let ambiguousMonths: Set<String> = ["may", "march", "mar"]

    private static func month(named word: String) -> Int? {
        (monthNames.firstIndex(of: word) ?? shortMonths.firstIndex(of: word)).map { $0 + 1 }
    }

    private func year(_ word: String) -> Int? {
        guard word.count == 4, let value = Int(word) else { return nil }
        return (1990...calendar.component(.year, from: now)).contains(value) ? value : nil
    }

    /// Whether summer comes at the end of the year where the person is.
    static func isSouthern(_ calendar: Calendar) -> Bool {
        let region = calendar.locale?.region?.identifier ?? Locale.current.region?.identifier ?? ""
        return ["AR", "AU", "BO", "BR", "CL", "NZ", "PY", "UY", "ZA"].contains(region)
    }
}

extension HistoryRecall.Season {
    init?(named word: String) {
        if word == "fall" {
            self = .autumn
        } else {
            self.init(rawValue: word)
        }
    }

    /// The month the season begins in, by the meteorological seasons.
    func firstMonth(southern: Bool) -> Int {
        let north = switch self {
        case .spring: 3
        case .summer: 6
        case .autumn: 9
        case .winter: 12
        }
        return southern ? (north + 5) % 12 + 1 : north
    }
}

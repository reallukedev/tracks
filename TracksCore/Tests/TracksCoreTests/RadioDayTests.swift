import Testing
@testable import TracksCore

@Suite("Tracks Radio's day")
struct RadioDayTests {
    @Test("by default nights are calm, mornings gentle and afternoons the brightest")
    func standardDay() {
        let day = RadioDay.standard
        #expect(day[.night] == .calm)
        #expect(day[.lateNight] == .calm)
        #expect(day[.earlyMorning] < day[.morning])
        #expect(day[.morning] < day[.afternoon])
        #expect(day[.evening] < day[.afternoon])
        #expect(RadioDay.Part.allCases.allSatisfy { day[$0] <= day[.afternoon] })
        #expect(day.isStandard)
    }

    @Test("the parts cover the day with no gaps, in order from early morning", arguments: [false, true])
    func partsCoverTheDay(isWeekend: Bool) {
        let parts = RadioDay.Part.allCases
        for (part, next) in zip(parts, parts.dropFirst()) where part != .night {
            #expect(part.endHour(isWeekend: isWeekend) == next.startHour(isWeekend: isWeekend))
        }
        #expect(RadioDay.Part.night.endHour(isWeekend: isWeekend) == 24)
        #expect(RadioDay.Part.lateNight.startHour(isWeekend: isWeekend) == 0)
        for part in parts {
            // Long enough that the easing into it and out of it never overlap.
            #expect(part.endHour(isWeekend: isWeekend) - part.startHour(isWeekend: isWeekend) >= 3)
            #expect(RadioDay.Part(hour: part.startHour(isWeekend: isWeekend), isWeekend: isWeekend) == part)
            #expect(RadioDay.Part(hour: part.endHour(isWeekend: isWeekend) - 1, isWeekend: isWeekend) == part)
        }
    }

    @Test("on a weekend the morning parts start an hour later")
    func weekendParts() {
        #expect(RadioDay.Part(hour: 5) == .earlyMorning)
        #expect(RadioDay.Part(hour: 5, isWeekend: true) == .lateNight)
        #expect(RadioDay.Part(hour: 12, isWeekend: true) == .morning)
        #expect(RadioDay.Part(hour: 21, isWeekend: true) == .night)
    }

    @Test("a part plays its own feel away from its edges")
    func feelHolds() {
        var day = RadioDay.standard
        day[.afternoon] = .energetic
        #expect(day.energy(atHour: 14.5) == RadioDay.Feel.energetic.energy)
        #expect(day.energy(atHour: 2.5) == RadioDay.Feel.calm.energy)
    }

    @Test("a change of feel eases over the hour either side, halfway at the change")
    func easing() {
        var day = RadioDay.standard
        day[.evening] = .energetic
        day[.night] = .calm
        let before = day.energy(atHour: 20)
        let atChange = day.energy(atHour: 21)
        let after = day.energy(atHour: 22)
        #expect(before == RadioDay.Feel.energetic.energy)
        #expect(abs(atChange - 0.5) < 0.0001)
        #expect(after == RadioDay.Feel.calm.energy)
        // Every quarter hour down the slope is calmer than the one before.
        let slope = stride(from: 20.0, through: 22.0, by: 0.25).map { day.energy(atHour: $0) }
        #expect(zip(slope, slope.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test("the curve runs on through midnight without a jump")
    func midnight() {
        var day = RadioDay.standard
        day[.night] = .upbeat
        day[.lateNight] = .calm
        #expect(abs(day.energy(atHour: 0) - day.energy(atHour: 24)) < 0.0001)
        #expect(abs(day.energy(atHour: 23.999) - day.energy(atHour: 0)) < 0.01)
        #expect(day.energy(atHour: 23.5) > day.energy(atHour: 0.5))
    }

    @Test("choosing a part's standard feel leaves the day standard")
    func settingStandard() {
        var day = RadioDay.standard
        day[.morning] = .energetic
        #expect(day.isStandard == false)
        day[.morning] = RadioDay.standardFeel(for: .morning)
        #expect(day.isStandard)
        #expect(day == .standard)
    }

    @Test("the calmest and brightest parts are the first of each, from early morning")
    func extremes() {
        #expect(RadioDay.standard.calmest == .night)
        #expect(RadioDay.standard.brightest == .afternoon)
        #expect(RadioDay.standard.isFlat == false)
        var day = RadioDay.standard
        day[.morning] = .energetic
        day[.afternoon] = .energetic
        day[.earlyMorning] = .calm
        #expect(day.brightest == .morning)
        #expect(day.calmest == .earlyMorning)
        let flat = RadioDay(Dictionary(uniqueKeysWithValues: RadioDay.Part.allCases.map { ($0, .balanced) }))
        #expect(flat.isFlat)
    }

    @Test("a day survives storage, and anything unreadable is the standard day")
    func storage() {
        var day = RadioDay.standard
        day[.lateNight] = .easy
        day[.afternoon] = .energetic
        #expect(RadioDay(stored: day.stored) == day)
        #expect(RadioDay(stored: "") == .standard)
        #expect(RadioDay(stored: "not json") == .standard)
    }

    @Test("parts and feels it doesn't know are skipped, and the rest still read")
    func unknownParts() {
        let stored = #"{"feels":{"brunch":"calm","morning":"energetic","night":"loud"}}"#
        let day = RadioDay(stored: stored)
        #expect(day[.morning] == .energetic)
        #expect(day[.night] == .calm)
    }
}

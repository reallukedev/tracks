import Testing
import Foundation
@testable import TracksCore

@Suite("Resume window")
struct ResumeWindowTests {
    let saved = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("the default keeps a song for a day")
    func standardIsADay() {
        #expect(ResumeWindow.standard == .oneDay)
        #expect(ResumeWindow.oneDay.keeps(savedAt: saved, now: saved.addingTimeInterval(23 * 3600)))
        #expect(!ResumeWindow.oneDay.keeps(savedAt: saved, now: saved.addingTimeInterval(25 * 3600)))
    }

    @Test("each window keeps a song for exactly its length", arguments: ResumeWindow.allCases.filter { $0 != .always })
    func boundary(window: ResumeWindow) throws {
        let duration = try #require(window.duration)
        #expect(window.keeps(savedAt: saved, now: saved.addingTimeInterval(duration)))
        #expect(!window.keeps(savedAt: saved, now: saved.addingTimeInterval(duration + 1)))
    }

    @Test("always keeps a song however long ago")
    func always() {
        #expect(ResumeWindow.always.duration == nil)
        #expect(ResumeWindow.always.keeps(savedAt: saved, now: saved.addingTimeInterval(365 * 24 * 3600)))
    }

    @Test("a save from the future still counts")
    func clockSetBack() {
        #expect(ResumeWindow.oneHour.keeps(savedAt: saved, now: saved.addingTimeInterval(-600)))
    }

    @Test("windows are listed shortest first")
    func order() {
        let durations = ResumeWindow.allCases.compactMap(\.duration)
        #expect(durations == durations.sorted())
        #expect(ResumeWindow.allCases.last == .always)
    }

    @Test("a song picks up a few seconds before where it was left")
    func stepsBack() {
        #expect(ResumePoint.time(leftAt: 95, duration: 200) == 92)
    }

    @Test("a song barely started, or nearly over, starts from the top")
    func fromTheTop() {
        #expect(ResumePoint.time(leftAt: 4, duration: 200) == 0)
        #expect(ResumePoint.time(leftAt: 198, duration: 200) == 0)
        #expect(ResumePoint.time(leftAt: .nan, duration: 200) == 0)
    }

    @Test("a song with no length picks up where it was left")
    func noDuration() {
        #expect(ResumePoint.time(leftAt: 600, duration: nil) == 597)
    }
}

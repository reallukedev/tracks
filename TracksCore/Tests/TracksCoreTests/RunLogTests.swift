import Foundation
import Testing
@testable import TracksCore

@Suite("Unexpected quits")
struct RunLogTests {
    let scratch = ScratchDefaults()
    var log: RunLog { RunLog(suiteName: scratch.suiteName) }

    init() {
        RunLog(suiteName: scratch.suiteName).reopensAutomatically = true
    }

    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @discardableResult
    private func begin(
        at offset: TimeInterval = 0,
        pid: Int32 = 100,
        build: String = "24",
        debugged: Bool = false
    ) -> UnexpectedQuit? {
        log.beginRun(
            version: "1.0",
            build: build,
            processID: pid,
            isDebugged: debugged,
            now: start.addingTimeInterval(offset)
        )
    }

    @Test("the first launch has nothing to report")
    func firstLaunch() {
        #expect(begin() == nil)
    }

    @Test("a run that was quit isn't reported")
    func cleanQuit() {
        begin()
        log.endCleanly(now: start.addingTimeInterval(60))
        #expect(begin(at: 120, pid: 101) == nil)
    }

    @Test("a run that stopped unseen is reported at its last heartbeat")
    func unseenStop() throws {
        begin()
        log.heartbeat(now: start.addingTimeInterval(300))

        let quit = try #require(begin(at: 900, pid: 101))
        #expect(quit.stoppedAt == start.addingTimeInterval(300))
        #expect(!quit.stopTimeIsExact)
        #expect(!quit.reopenedAutomatically)
        #expect(quit.reopenedAt == start.addingTimeInterval(900))
        #expect(quit.gap == 600)
    }

    @Test("the watchdog's time is exact, and its reopen is reported as automatic")
    func watchdogStop() throws {
        begin()
        log.heartbeat(now: start.addingTimeInterval(300))
        #expect(log.recordTermination(processID: 100, now: start.addingTimeInterval(330)) == .reopen)

        let quit = try #require(begin(at: 332, pid: 101))
        #expect(quit.stoppedAt == start.addingTimeInterval(330))
        #expect(quit.stopTimeIsExact)
        #expect(quit.reopenedAutomatically)
    }

    @Test("the watchdog leaves a quit app closed")
    func watchdogAfterQuit() {
        begin()
        log.endCleanly(now: start.addingTimeInterval(60))
        #expect(log.recordTermination(processID: 100, now: start.addingTimeInterval(61)) == .quit)
    }

    @Test("with reopening off, the app stays closed and the stop time is still exact")
    func reopeningOff() throws {
        log.reopensAutomatically = false
        begin()
        #expect(log.recordTermination(processID: 100, now: start.addingTimeInterval(330)) == .leftClosed)

        let quit = try #require(begin(at: 900, pid: 101))
        #expect(quit.stoppedAt == start.addingTimeInterval(330))
        #expect(quit.stopTimeIsExact)
        #expect(!quit.reopenedAutomatically)
    }

    @Test("an app ended while someone was using the Mac stays closed, as after Force Quit")
    func forceQuit() {
        begin()
        #expect(log.recordTermination(processID: 100, secondsSinceInput: 2) == .leftClosed)
    }

    @Test("an app ended while the Mac sat idle is reopened")
    func idleEnd() {
        begin()
        #expect(log.recordTermination(processID: 100, secondsSinceInput: 600) == .reopen)
    }

    @Test("reopening is off until the person turns it on")
    func offByDefault() {
        let fresh = ScratchDefaults()
        #expect(!RunLog(suiteName: fresh.suiteName).reopensAutomatically)
    }

    @Test("a watchdog from another run doesn't act on this one")
    func staleWatchdog() {
        begin(pid: 100)
        #expect(log.recordTermination(processID: 99) == .unknown)
    }

    @Test("an update isn't reported as an unexpected quit")
    func update() {
        begin(build: "24")
        #expect(begin(at: 60, pid: 101, build: "25") == nil)
    }

    @Test("a run under the debugger isn't reported")
    func debugger() {
        begin(debugged: true)
        #expect(begin(at: 60, pid: 101) == nil)
    }

    @Test("the notice stays until it's dismissed")
    func dismissal() throws {
        begin()
        let quit = try #require(begin(at: 60, pid: 101))

        // Quit and reopened by hand before looking: still there.
        log.endCleanly(now: start.addingTimeInterval(90))
        #expect(begin(at: 120, pid: 102) == quit)

        log.dismissNotice()
        #expect(log.notice == nil)
    }

    @Test("reopening stops after a few in a short time, and resumes once they age out")
    func crashLoop() {
        var now: TimeInterval = 0
        for pid in Int32(100)..<Int32(100 + RunLog.maxRelaunches) {
            begin(at: now, pid: pid)
            #expect(log.recordTermination(processID: pid, now: start.addingTimeInterval(now + 5)) == .reopen)
            now += 10
        }
        begin(at: now, pid: 200)
        #expect(log.recordTermination(processID: 200, now: start.addingTimeInterval(now + 5)) == .gaveUp)

        let later = now + RunLog.relaunchWindow
        begin(at: later, pid: 201)
        #expect(log.recordTermination(processID: 201, now: start.addingTimeInterval(later + 5)) == .reopen)
    }
}

@Suite("Debug report")
struct DebugReportTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test("it's a fenced block with aligned keys and every section")
    func layout() {
        let report = DebugReport(
            sections: [
                .init("App", [("Version", "1.0 (24)"), ("macOS", "27.0")]),
                .init("Empty", []),
                .init("Store", [("Backing", "App Group")]),
            ],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let text = report.markdown(timeZone: utc)
        #expect(text.hasPrefix("### Tracks debug info\n\n```\n"))
        #expect(text.hasSuffix("\n```"))
        #expect(text.contains("[App]\nVersion    1.0 (24)\nmacOS      27.0"))
        #expect(text.contains("Generated  1970-01-01T00:00:00Z (\(utc.identifier))"))
        #expect(!text.contains("[Empty]"))
    }

    @Test("a value with a line break stays on one line")
    func multilineValue() {
        let text = DebugReport(sections: [.init("Errors", [("Sync", "first\nsecond")])])
            .markdown(timeZone: utc)
        #expect(text.contains("Sync       first second"))
    }

    @Test("an unseen stop says its time is approximate")
    func approximateStop() {
        let quit = UnexpectedQuit(
            launchedAt: Date(timeIntervalSince1970: 0),
            stoppedAt: Date(timeIntervalSince1970: 3_600),
            stopTimeIsExact: false,
            reopenedAt: Date(timeIntervalSince1970: 3_725),
            reopenedAutomatically: false,
            version: "1.0",
            build: "24"
        )
        let rows = DebugReport.section(for: quit, timeZone: utc).rows
        let values = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
        #expect(values["Stopped"]?.contains("may be up to a minute early") == true)
        #expect(values["Reopened"]?.contains("automatically") == false)
        #expect(values["Not recording for"] == "2 min, 5 sec")
    }

    @Test("disk space reads as free, total and how full")
    func diskSpace() {
        let text = DebugReport.describe(available: 14_000_000_000, total: 460_000_000_000)
        #expect(text.hasPrefix("14 GB free of 460 GB"))
        #expect(text.hasSuffix("(97% full)"))
    }
}

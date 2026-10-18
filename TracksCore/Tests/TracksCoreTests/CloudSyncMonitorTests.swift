import Foundation
import Testing
@testable import TracksCore

/// Telling a store that opened with sync apart from one that is actually syncing.
@MainActor
@Suite("iCloud sync health")
struct CloudSyncMonitorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a refused export is reported")
    func exportFailureIsReported() throws {
        let monitor = CloudSyncMonitor()

        monitor.record(.export, succeeded: false, message: "Refused", at: start)

        let failure = try #require(monitor.failure)
        #expect(failure.activity == .export)
        #expect(failure.message == "Refused")
        #expect(failure.date == start)
    }

    /// The Mac imported nothing while every export was refused. A success of a different kind
    /// must not make that look fixed.
    @Test("a success of another kind leaves the failure showing")
    func otherSuccessKeepsFailure() {
        let monitor = CloudSyncMonitor()

        monitor.record(.export, succeeded: false, message: "Refused", at: start)
        monitor.record(.import, succeeded: true, message: nil, at: start.addingTimeInterval(1))

        #expect(monitor.failure?.activity == .export)
    }

    @Test("a success of the same kind clears the failure")
    func sameSuccessClearsFailure() {
        let monitor = CloudSyncMonitor()

        monitor.record(.export, succeeded: false, message: "Refused", at: start)
        monitor.record(.export, succeeded: true, message: nil, at: start.addingTimeInterval(1))

        #expect(monitor.failure == nil)
    }

    @Test("a failure with no error still says something")
    func failureWithoutMessage() throws {
        let monitor = CloudSyncMonitor()

        monitor.record(.setup, succeeded: false, message: nil, at: start)

        let failure = try #require(monitor.failure)
        #expect(!failure.message.isEmpty)
    }

    @Test("an import or export marks the last sync, setup doesn't")
    func lastSyncedFollowsTransfers() {
        let monitor = CloudSyncMonitor()

        monitor.record(.setup, succeeded: true, message: nil, at: start)
        #expect(monitor.lastSynced == nil)

        monitor.record(.export, succeeded: true, message: nil, at: start.addingTimeInterval(10))
        monitor.record(.import, succeeded: false, message: "Offline", at: start.addingTimeInterval(20))

        #expect(monitor.lastSynced == start.addingTimeInterval(10))
    }
}

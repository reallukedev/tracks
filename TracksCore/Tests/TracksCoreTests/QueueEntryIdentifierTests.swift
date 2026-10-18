import Testing
import Foundation
@testable import TracksCore

/// Every identifier here was observed on a real device on 2026-09-08. The format is
/// undocumented, so these fail if Apple changes it.
@Suite("Queue entry identifiers")
struct QueueEntryIdentifierTests {

    @Test("radio entries end in STREAM", arguments: [
        "Jzb4lWyve::STREAM",   // Apple Music Chill
        "PxDIf4ejk::STREAM",   // Apple Music 1
        "o6C8OJs7I::STREAM",   // a personal artist station
    ])
    func radioEntries(raw: String) throws {
        let identifier = try #require(QueueEntryIdentifier(raw))
        #expect(identifier.isStream)
    }

    @Test("on-demand entries carry an opaque item id", arguments: [
        "PRhKeIIy0::6ostOUDHU",
        "PRhKeIIy0::EHYCyckzc",
    ])
    func onDemandEntries(raw: String) throws {
        let identifier = try #require(QueueEntryIdentifier(raw))
        #expect(!identifier.isStream)
    }

    /// Session boundaries depend on this.
    @Test("the queue id is stable within one queue and distinct between them")
    func queueIdentity() throws {
        let first = try #require(QueueEntryIdentifier("PRhKeIIy0::6ostOUDHU"))
        let second = try #require(QueueEntryIdentifier("PRhKeIIy0::EHYCyckzc"))
        let station = try #require(QueueEntryIdentifier("PxDIf4ejk::STREAM"))

        #expect(first.queueID == second.queueID)
        #expect(first.queueID != station.queueID)
    }

    @Test("two different stations have different queue ids")
    func distinctStations() throws {
        let chill = try #require(QueueEntryIdentifier("Jzb4lWyve::STREAM"))
        let one = try #require(QueueEntryIdentifier("PxDIf4ejk::STREAM"))
        #expect(chill.queueID != one.queueID)
    }

    @Test("malformed identifiers are rejected rather than guessed at", arguments: [
        "", "STREAM", "no-separator", "::STREAM", "queue::", "a::b::c",
    ])
    func malformed(raw: String) {
        #expect(QueueEntryIdentifier(raw) == nil)
    }
}

@Suite("iOS radio detection")
struct IOSRadioDetectionTests {

    @Test("a STREAM entry is radio, stated rather than inferred")
    func streamIsRadio() throws {
        let identifier = try #require(QueueEntryIdentifier("PxDIf4ejk::STREAM"))
        let verdict = RadioHeuristic.evaluate(.init(duration: 223, entryIdentifier: identifier))
        #expect(verdict == .radio(confidence: .stated))
        #expect(verdict.shouldCapture)
    }

    /// On iOS a resolved radio track has a real duration (Dai Dai came back as 223 seconds),
    /// so the macOS duration rule would call it on demand.
    @Test("a real duration does not override the entry id")
    func durationDoesNotOverride() throws {
        let identifier = try #require(QueueEntryIdentifier("PxDIf4ejk::STREAM"))
        let verdict = RadioHeuristic.evaluate(
            .init(duration: 223, hasComposer: true, playerPosition: 28.2, entryIdentifier: identifier)
        )
        #expect(verdict.shouldCapture)
    }

    @Test("an album entry is on demand even with no duration reported yet")
    func albumIsOnDemand() throws {
        let identifier = try #require(QueueEntryIdentifier("PRhKeIIy0::6ostOUDHU"))
        let verdict = RadioHeuristic.evaluate(.init(duration: nil, entryIdentifier: identifier))
        #expect(verdict == .onDemand)
        #expect(!verdict.shouldCapture)
    }

    @Test("the user's switch still outranks the entry id")
    func userStillWins() throws {
        let identifier = try #require(QueueEntryIdentifier("PRhKeIIy0::6ostOUDHU"))
        let verdict = RadioHeuristic.evaluate(
            .init(duration: 104, entryIdentifier: identifier, userForcedCapture: true)
        )
        #expect(verdict == .radio(confidence: .asserted))
    }

    @Test("macOS still falls back to the duration signal")
    func macOSFallback() {
        let verdict = RadioHeuristic.evaluate(.init(duration: nil, playerPosition: 0))
        #expect(verdict == .radio(confidence: .corroborated))
    }
}

import Testing
import Foundation
@testable import TracksCore

@Suite("Songs asked of a server")
struct ServerKeepsTests {
    let askedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("a song asked for is waited for, and no other")
    func waits() {
        var keeps = ServerKeeps()
        #expect(keeps.isEmpty)
        keeps.ask(for: "night drive|mara solis", at: askedAt)
        #expect(keeps.isWaiting(for: "night drive|mara solis"))
        #expect(keeps.isWaiting(for: "tidal|mara solis") == false)
        #expect(keeps.isEmpty == false)
    }

    @Test("a sync that brings the song in ends the wait, and leaves the others waiting")
    func arrives() {
        var keeps = ServerKeeps()
        keeps.ask(for: "night drive|mara solis", at: askedAt)
        keeps.ask(for: "tidal|mara solis", at: askedAt)
        keeps.settle(arrived: ["night drive|mara solis", "something else|nova harbor"], now: askedAt.addingTimeInterval(180))
        #expect(keeps.isWaiting(for: "night drive|mara solis") == false)
        #expect(keeps.isWaiting(for: "tidal|mara solis"))
    }

    @Test("a song is given up on once a day has passed, not before", arguments: [
        (ServerKeeps.patience - 1, true),
        (ServerKeeps.patience, false),
        (ServerKeeps.patience * 2, false),
    ])
    func patience(waited: TimeInterval, stillWaiting: Bool) {
        var keeps = ServerKeeps()
        keeps.ask(for: "night drive|mara solis", at: askedAt)
        keeps.settle(arrived: [], now: askedAt.addingTimeInterval(waited))
        #expect(keeps.isWaiting(for: "night drive|mara solis") == stillWaiting)
    }

    @Test("asking again starts the wait over")
    func askAgain() {
        var keeps = ServerKeeps()
        keeps.ask(for: "night drive|mara solis", at: askedAt)
        keeps.ask(for: "night drive|mara solis", at: askedAt.addingTimeInterval(ServerKeeps.patience))
        keeps.settle(arrived: [], now: askedAt.addingTimeInterval(ServerKeeps.patience + 60))
        #expect(keeps.isWaiting(for: "night drive|mara solis"))
    }

    @Test("what's waited for survives being saved and read back")
    func roundTrip() throws {
        var keeps = ServerKeeps()
        keeps.ask(for: "night drive|mara solis", at: askedAt)
        let saved = try JSONEncoder().encode(["home": keeps])
        let read = try JSONDecoder().decode([String: ServerKeeps].self, from: saved)
        #expect(read == ["home": keeps])
    }
}

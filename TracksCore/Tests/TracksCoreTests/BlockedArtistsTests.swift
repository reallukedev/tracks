import Testing
import Foundation
@testable import TracksCore

@Suite("Blocked artists")
struct BlockedArtistsTests {
    @Test("A blocked artist's songs are left out, however the name is cased or accented")
    func matchesFolded() {
        let blocked = BlockedArtists(["Mara Solís"])
        #expect(blocked.blocks(songBy: "mara solis"))
        #expect(blocked.blocks(songBy: "MARA SOLÍS"))
        #expect(!blocked.blocks(songBy: "Mara"))
    }

    @Test("Songs they're featured on are left out too", arguments: [
        "Umbra feat. Mara Solis",
        "Umbra (feat. Mara Solis)",
        "Umbra & Mara Solis",
        "Mara Solis, Umbra",
        "Umbra x Mara Solis",
    ])
    func matchesCredits(credit: String) {
        #expect(BlockedArtists(["Mara Solis"]).blocks(songBy: credit))
    }

    @Test("Names match whole, never inside another's")
    func wholeNamesOnly() {
        let blocked = BlockedArtists(["Air"])
        #expect(!blocked.blocks(songBy: "Blair"))
        #expect(!blocked.blocks(songBy: "Airborne"))
        #expect(blocked.blocks(songBy: "Air"))
    }

    @Test("A song identity is read for its artist")
    func matchesIdentity() {
        let blocked = BlockedArtists(["Nova Harbor"])
        #expect(blocked.blocks(songIdentity: HistoryImport.key(title: "Golden Moon", artistName: "Nova Harbor")))
        #expect(!blocked.blocks(songIdentity: HistoryImport.key(title: "Nova Harbor", artistName: "Paper Lanterns")))
        #expect(!blocked.blocks(songIdentity: "no separator"))
    }

    @Test("Blocking twice keeps one; unblocking takes it out whatever the case")
    func blockAndUnblock() {
        var blocked = BlockedArtists()
        let first = blocked.block("Umbra")
        let again = blocked.block("  umbra ")
        #expect(first)
        #expect(!again)
        #expect(blocked.names == ["Umbra"])
        blocked.unblock("UMBRA")
        #expect(blocked.isEmpty)
        #expect(blocked.names.isEmpty)
    }

    @Test("Blank names and repeats in what was stored are dropped, first kept")
    func cleansStored() {
        let blocked = BlockedArtists(["Umbra", "", "  ", "umbra", "Mara Solis"])
        #expect(blocked.names == ["Umbra", "Mara Solis"])
    }

    @Test("Nobody is blocked to begin with")
    func emptyByDefault() {
        let blocked = BlockedArtists()
        #expect(blocked.isEmpty)
        #expect(!blocked.blocks(songBy: "Anyone"))
    }

    @Test("Listening signals leave out a blocked artist's songs, and don't keep the list")
    func signalsExclude() throws {
        var signals = ListeningSignals()
        let song = HistoryImport.key(title: "Golden Moon", artistName: "Nova Harbor")
        #expect(!signals.excludes(song))
        signals.blocked = BlockedArtists(["Nova Harbor"])
        #expect(signals.excludes(song))

        let data = try JSONEncoder().encode(signals)
        let decoded = try JSONDecoder().decode(ListeningSignals.self, from: data)
        #expect(decoded.blocked.isEmpty)
    }

    @Test("Signals saved before blocking existed still load")
    func oldSignalsLoad() throws {
        let data = Data(#"{"skips":{},"suggestLess":["a\u001fb"]}"#.utf8)
        let signals = try JSONDecoder().decode(ListeningSignals.self, from: data)
        #expect(signals.suggestLess == ["a\u{1F}b"])
    }

    @Test("Settings keep the list in order, across a read and a write")
    func settingsRoundTrip() {
        let scratch = ScratchDefaults()
        let settings = scratch.settings
        #expect(settings.blockedArtists.isEmpty)
        var blocked = settings.blockedArtists
        blocked.block("Umbra")
        blocked.block("Mara Solis")
        settings.blockedArtists = blocked
        #expect(settings.blockedArtists.names == ["Umbra", "Mara Solis"])
    }
}

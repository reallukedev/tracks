import Testing
import Foundation
@testable import TracksCore

@Suite("Songs Tracks’ player passed over")
struct PassedOverSongsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let key = HistoryImport.key(title: "Video Games", artistName: "Lana Del Rey")

    @Test("A song passed over is known to imports after it")
    func passedOverIsKnown() {
        var songs = PassedOverSongs()
        songs.note(key, at: now)
        #expect(songs.keys(since: now.addingTimeInterval(-60)) == [key])
        #expect(songs.keys(since: now.addingTimeInterval(60)).isEmpty)
    }

    @Test("Passes older than the memory are forgotten at the next one")
    func oldPassesAreTrimmed() {
        var songs = PassedOverSongs()
        songs.note("old", at: now.addingTimeInterval(-PassedOverSongs.memory - 1))
        songs.note(key, at: now)
        #expect(songs.entries.count == 1)
        #expect(songs.keys(since: .distantPast) == [key])
    }

    @Test("The list never grows past its limit, the oldest going first")
    func keepsToTheLimit() {
        var songs = PassedOverSongs()
        for index in 0...PassedOverSongs.limit {
            songs.note("song \(index)", at: now.addingTimeInterval(Double(index)))
        }
        #expect(songs.entries.count == PassedOverSongs.limit)
        #expect(!songs.keys(since: .distantPast).contains("song 0"))
        #expect(songs.keys(since: .distantPast).contains("song \(PassedOverSongs.limit)"))
    }

    @Test("Two devices' lists joined as a sorted union stay oldest first")
    func unionSortsByTime() {
        let mac = PassedOverSongs.entry("b", at: now)
        let phone = PassedOverSongs.entry("a", at: now.addingTimeInterval(-10))
        let joined = PassedOverSongs(Set([mac, phone]).sorted())
        #expect(joined.entries == [phone, mac])
    }

    @Test("A key with the import key's own separator in it reads back whole")
    func keyKeepsItsSeparator() throws {
        let parsed = try #require(PassedOverSongs.parse(PassedOverSongs.entry(key, at: now)))
        #expect(parsed.key == key)
        #expect(parsed.at == now)
    }
}

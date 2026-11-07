import Foundation
import Testing
@testable import TracksCore

struct MusicGenreTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("the ways songs are tagged fold into the genre Play has a page for", arguments: [
        ("Hip-Hop/Rap", "hip-hop"),
        ("Rap", "hip-hop"),
        ("R&B/Soul", "r-b"),
        ("Soul", "r-b"),
        ("Indie Pop", "alternative"),
        ("Dance", "electronic"),
        ("House", "electronic"),
        ("Singer/Songwriter", "singer-songwriter"),
        ("Christian & Gospel", "christian"),
        ("Música Mexicana", "latin"),
        ("K-Pop", "k-pop"),
        ("Pop", "pop"),
    ])
    func folding(tag: String, expected: String) {
        #expect(MusicGenre.of(genre: tag)?.id == expected)
    }

    @Test("tags Play has no page for, and none at all, belong nowhere")
    func unknown() {
        #expect(MusicGenre.of(genre: "Spoken Word") == nil)
        #expect(MusicGenre.of(genre: "Music") == nil)
        #expect(MusicGenre.of(genre: nil) == nil)
    }

    @Test("every genre has its own key and its own Apple Music id")
    func unique() {
        #expect(Set(MusicGenre.all.map(\.id)).count == MusicGenre.all.count)
        #expect(Set(MusicGenre.all.map(\.appleMusicID)).count == MusicGenre.all.count)
    }

    /// Ten plays of a rock song, three of a hip-hop one, one of a song with no genre.
    func history() -> ListeningHistory {
        var plays: [CaptureStat] = []
        let songs: [(title: String, artist: String, genre: String?, plays: Int)] = [
            ("Loud", "Band", "Rock", 10),
            ("Bars", "MC", "Hip-Hop/Rap", 3),
            ("Mystery", "Nobody", nil, 1),
        ]
        var metadata: [String: SongMetadata] = [:]
        for song in songs {
            for play in 0..<song.plays {
                plays.append(CaptureStat(songKey: song.title, songID: song.title, title: song.title, artistName: song.artist, capturedAt: now.addingTimeInterval(-Double(play + 1) * 86_400)))
            }
            if let genre = song.genre {
                metadata[HistoryImport.key(title: song.title, artistName: song.artist)] = SongMetadata(genre: genre, releaseYear: nil)
            }
        }
        return ListeningHistory(plays).with(artistArtwork: [:], songMetadata: metadata)
    }

    @Test("genres you play come first, the most played first, then the rest in their usual order")
    func ranking() throws {
        let profiles = MusicGenre.profiles(in: history(), now: now)
        #expect(profiles.count == MusicGenre.all.count)
        #expect(profiles.prefix(2).map(\.genre.id) == ["rock", "hip-hop"])
        #expect(profiles.prefix(2).map(\.plays) == [10, 3])
        let first = try #require(profiles.dropFirst(2).first)
        #expect(first.genre.id == "pop")
        #expect(first.plays == 0)
        #expect(first.songs.isEmpty)
    }

    @Test("a genre's profile has your songs and artists in it, and nothing from other genres")
    func profile() throws {
        let rock = try #require(MusicGenre.profiles(in: history(), now: now).first)
        #expect(rock.songs.map(\.title) == ["Loud"])
        #expect(rock.artists.map(\.name) == ["Band"])
        #expect(rock.artists.first?.plays == 10)
    }

    @Test("a genre's station plays your songs in it, and new finds from its charts")
    func station() throws {
        let find = MixSong(songIdentity: "find", songID: "find", title: "Find", artistName: "New Band", albumTitle: nil, artworkURL: nil, plays: 0, lastHeard: .distantPast, genre: "Rock")
        let rock = try #require(MusicGenre.all.first { $0.id == "rock" })
        let mix = LiveMix.genre(rock, from: history(), newFinds: [find], now: now, seed: 1)
        let titles = Set(mix.candidates.map(\.song.title))
        #expect(titles == ["Loud", "Find"])
        #expect(mix.candidates.first { $0.song.title == "Find" }?.isNew == true)
        // Only one song of yours in it: new finds for half the picks.
        #expect(mix.newShare == 0.5)
    }

    @Test("with none of your songs in a genre, its station is all new finds")
    func stationFromNothing() throws {
        let jazz = try #require(MusicGenre.all.first { $0.id == "jazz" })
        let mix = LiveMix.genre(jazz, from: history(), now: now, seed: 2)
        #expect(mix.isEmpty)
        #expect(mix.newShare == 1)
    }
}

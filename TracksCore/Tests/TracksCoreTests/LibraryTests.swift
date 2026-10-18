import Testing
import Foundation
@testable import TracksCore

/// A FLAC file's head, built by hand: STREAMINFO, then whatever blocks are given.
private func flac(sampleRate: Int, channels: Int, bitDepth: Int, samples: Int, blocks: [(type: UInt8, body: [UInt8])], id3: Bool = false) -> Data {
    var bytes: [UInt8] = []
    if id3 {
        // "ID3", version 4.0, no flags, a 20-byte tag of zeros.
        bytes += [0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 20] + [UInt8](repeating: 0, count: 20)
    }
    bytes += Array("fLaC".utf8)
    var info = [UInt8](repeating: 0, count: 34)
    let packed = UInt64(sampleRate) << 44 | UInt64(channels - 1) << 41 | UInt64(bitDepth - 1) << 36 | UInt64(samples)
    for index in 0..<8 { info[10 + index] = UInt8(truncatingIfNeeded: packed >> (56 - 8 * UInt64(index))) }
    let all: [(type: UInt8, body: [UInt8])] = [(0, info)] + blocks
    for (index, block) in all.enumerated() {
        let isLast: UInt8 = index == all.count - 1 ? 0x80 : 0
        let length = block.body.count
        bytes += [isLast | block.type, UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)]
        bytes += block.body
    }
    return Data(bytes)
}

private func littleEndian(_ value: Int) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

private func bigEndian(_ value: Int) -> [UInt8] {
    (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}

private func comments(_ fields: [String]) -> [UInt8] {
    let vendor = Array("reference libFLAC".utf8)
    var bytes = littleEndian(vendor.count) + vendor + littleEndian(fields.count)
    for field in fields {
        let utf8 = Array(field.utf8)
        bytes += littleEndian(utf8.count) + utf8
    }
    return bytes
}

private func picture(type: Int, data: [UInt8]) -> [UInt8] {
    let mime = Array("image/jpeg".utf8)
    return bigEndian(type) + bigEndian(mime.count) + mime + bigEndian(0) + [UInt8](repeating: 0, count: 16) + bigEndian(data.count) + data
}

@Suite("FLAC metadata")
struct FLACMetadataTests {
    @Test("reads the stream: sample rate, bit depth, channels and length")
    func streamInfo() throws {
        let metadata = try FLACMetadata.read(flac(sampleRate: 96_000, channels: 2, bitDepth: 24, samples: 96_000 * 185, blocks: []))
        #expect(metadata.sampleRate == 96_000)
        #expect(metadata.bitDepth == 24)
        #expect(metadata.channels == 2)
        #expect(metadata.duration == 185)
        #expect(metadata.format.detail == "24-bit/96 kHz")
        #expect(metadata.format.isHiRes)
    }

    @Test("reads Vorbis comments, whatever their case, with every artist")
    func tags() throws {
        let data = flac(sampleRate: 44_100, channels: 2, bitDepth: 16, samples: 44_100 * 60, blocks: [
            (4, comments([
                "TITLE=Night Drive", "artist=Mara Solis", "ARTIST=Nova Harbor", "AlbumArtist=Mara Solis",
                "ALBUM=Coastlines", "TRACKNUMBER=3/12", "DISCNUMBER=2", "DATE=2019-05-01", "GENRE=Indie Pop", "EMPTY=",
            ])),
        ])
        let metadata = try FLACMetadata.read(data)
        #expect(metadata.title == "Night Drive")
        #expect(metadata.artist == "Mara Solis, Nova Harbor")
        #expect(metadata.albumArtist == "Mara Solis")
        #expect(metadata.album == "Coastlines")
        #expect(metadata.trackNumber == 3)
        #expect(metadata.discNumber == 2)
        #expect(metadata.year == 2019)
        #expect(metadata.genre == "Indie Pop")
        #expect(metadata.comments["EMPTY"] == nil)
        #expect(metadata.format.detail == "16-bit/44.1 kHz")
        #expect(!metadata.format.isHiRes)
    }

    @Test("prefers the front cover over other pictures")
    func frontCover() throws {
        let data = flac(sampleRate: 48_000, channels: 2, bitDepth: 16, samples: 48_000, blocks: [
            (1, [UInt8](repeating: 0, count: 64)),
            (6, picture(type: 4, data: [1, 2, 3])),
            (6, picture(type: 3, data: [9, 9])),
        ])
        #expect(try FLACMetadata.read(data).picture?.data == Data([9, 9]))
    }

    @Test("steps over an ID3 tag in front of the stream")
    func id3() throws {
        let data = flac(sampleRate: 44_100, channels: 2, bitDepth: 16, samples: 44_100, blocks: [(4, comments(["TITLE=Tagged"]))], id3: true)
        #expect(try FLACMetadata.read(data).title == "Tagged")
    }

    @Test("a file that isn't FLAC, or ends early, is said to be")
    func damaged() {
        #expect(throws: FLACMetadata.ReadError.notFLAC) { try FLACMetadata.read(Data("RIFF....WAVE".utf8)) }
        let whole = flac(sampleRate: 44_100, channels: 2, bitDepth: 16, samples: 44_100, blocks: [(4, comments(["TITLE=X"]))])
        #expect(throws: FLACMetadata.ReadError.truncated) { try FLACMetadata.read(whole.prefix(whole.count - 3)) }
    }
}

private struct StubTransport: SubsonicTransport {
    let body: String
    var status = 200

    func data(for url: URL) async throws -> (Data, Int) { (Data(body.utf8), status) }
}

@Suite("Subsonic")
struct SubsonicTests {
    let server = SubsonicServer(id: "home", name: "Home", url: URL(string: "https://music.example.com")!, username: "luke", salt: "c19b2d")

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    @Test("the token is md5 of the password and salt, and the password never goes in the address")
    func token() throws {
        // The worked example from the Subsonic API documentation.
        #expect(SubsonicClient.token(password: "sesame", salt: "c19b2d") == "26719a1196d2a940705a59634eb18eab")
        let url = SubsonicClient(server: server, password: "sesame").url("ping")
        let query = query(url)
        #expect(url.path() == "/rest/ping")
        let salt = try #require(query["s"])
        #expect(query["t"] == SubsonicClient.token(password: "sesame", salt: salt))
        #expect(query["f"] == "json")
        #expect(!url.absoluteString.contains("sesame"))
    }

    /// With one salt for good, an address from any log signed every request after it.
    @Test("each request is signed with a salt of its own")
    func freshSaltPerRequest() {
        let client = SubsonicClient(server: server, password: "sesame")
        let first = query(client.url("ping"))
        let second = query(client.url("ping"))
        #expect(first["s"] != second["s"])
        #expect(first["t"] != second["t"])
        #expect(query(client.streamURL(songID: "7"))["s"] != query(client.streamURL(songID: "7"))["s"])
    }

    /// Covers are cached by address, so theirs can't change between launches.
    @Test("a cover's address stays the same")
    func stableCoverAddress() {
        let client = SubsonicClient(server: server, password: "sesame")
        #expect(client.coverArtURL(id: "al-1", size: 600) == client.coverArtURL(id: "al-1", size: 600))
        #expect(query(client.coverArtURL(id: "al-1"))["s"] == server.salt)
    }

    @Test("a plus in a username or search reaches the server as a plus")
    func plus() {
        var server = server
        server.username = "luke+music@example.com"
        let url = SubsonicClient(server: server, password: "x").url("search3", ["query": "Florence + the Machine"])
        let query = url.query(percentEncoded: true) ?? ""
        #expect(query.contains("u=luke%2Bmusic@example.com"))
        #expect(query.contains("query=Florence%20%2B%20the%20Machine"))
        #expect(!query.contains("+"))
    }

    @Test("streams the original file unless a bit rate is asked for")
    func stream() {
        let client = SubsonicClient(server: server, password: "sesame")
        #expect(client.streamURL(songID: "7").absoluteString.contains("format=raw"))
        #expect(client.streamURL(songID: "7", maxBitRate: 320).absoluteString.contains("maxBitRate=320"))
    }

    @Test("an address is tidied as it's typed")
    func address() {
        #expect(SubsonicServer.address(from: " music.example.com/ ")?.absoluteString == "https://music.example.com")
        #expect(SubsonicServer.address(from: "http://192.168.1.4:4533")?.absoluteString == "http://192.168.1.4:4533")
        #expect(SubsonicServer.address(from: "ftp://nope") == nil)
        #expect(SubsonicServer.address(from: "") == nil)
    }

    @Test("reads albums whose ids come as numbers or strings")
    func lenientIDs() async throws {
        let client = SubsonicClient(server: server, password: "x", transport: StubTransport(body: """
        {"subsonic-response":{"status":"ok","version":"1.16.1","albumList2":{"album":[
          {"id":"al-1","name":"Coastlines","artist":"Mara Solis","artistId":"ar-1","songCount":9,"year":2019},
          {"id":42,"name":"Numbers","artistId":7}
        ]}}}
        """))
        let albums = try await client.albums(.newest)
        #expect(albums.map(\.id) == ["al-1", "42"])
        #expect(albums[1].artistId == "7")
        #expect(albums[0].year == 2019)
    }

    @Test("a song's added date is read however the server writes it", arguments: [
        ("2024-03-01T18:22:10.000Z", true),
        ("2024-03-01T18:22:10Z", true),
        ("2024-03-01T18:22:10", true),
        ("last tuesday", false),
    ])
    func created(text: String, isRead: Bool) {
        var song = SubsonicSong(id: "s1", title: "Night Drive")
        song.created = text
        #expect((song.createdDate != nil) == isRead)
        if isRead {
            #expect(song.createdDate.map { Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: $0).day } == 1)
        }
    }

    @Test("an album's songs become your own, on that server, with their format")
    func albumSongs() async throws {
        let client = SubsonicClient(server: server, password: "x", transport: StubTransport(body: """
        {"subsonic-response":{"status":"ok","album":{"id":"al-1","name":"Coastlines","artist":"Mara Solis","song":[
          {"id":"s1","title":"Night Drive","artist":"Mara Solis","album":"Coastlines","track":1,"duration":201,"suffix":"flac","samplingRate":96000,"bitDepth":24,"coverArt":"al-1"}
        ]}}}
        """))
        let (album, songs) = try await client.album(id: "al-1")
        #expect(album.name == "Coastlines")
        let track = songs[0].track(on: "home")
        #expect(track.origin == .server(serverID: "home", songID: "s1"))
        #expect(track.format?.detail == "24-bit/96 kHz")
        #expect(track.artwork == .server(serverID: "home", coverID: "al-1"))
        #expect(track.identity == HistoryImport.key(title: "Night Drive", artistName: "Mara Solis"))
    }

    @Test("says why a server refused", arguments: [
        (40, SubsonicError.wrongCredentials),
        (30, SubsonicError.incompatible),
        (70, SubsonicError.notFound),
        (0, SubsonicError.server(code: 0, message: "Boom")),
    ])
    func errors(code: Int, expected: SubsonicError) async {
        let client = SubsonicClient(server: server, password: "x", transport: StubTransport(body: """
        {"subsonic-response":{"status":"failed","error":{"code":\(code),"message":"Boom"}}}
        """))
        await #expect(throws: expected) { try await client.ping() }
    }

    @Test("a page that isn't a Subsonic server is told apart from a server error")
    func notSubsonic() async {
        await #expect(throws: SubsonicError.notSubsonic) {
            try await SubsonicClient(server: server, password: "x", transport: StubTransport(body: "<html>Hello</html>")).ping()
        }
        await #expect(throws: SubsonicError.http(status: 404)) {
            try await SubsonicClient(server: server, password: "x", transport: StubTransport(body: "Not Found", status: 404)).ping()
        }
    }

    @Test("reads artists across the index and search results")
    func artistsAndSearch() async throws {
        let artists = try await SubsonicClient(server: server, password: "x", transport: StubTransport(body: """
        {"subsonic-response":{"status":"ok","artists":{"index":[{"name":"A","artist":[{"id":"1","name":"Arcade"}]},{"name":"B","artist":[{"id":"2","name":"Bloom","albumCount":3}]}]}}}
        """)).artists()
        #expect(artists.map(\.name) == ["Arcade", "Bloom"])

        let result = try await SubsonicClient(server: server, password: "x", transport: StubTransport(body: """
        {"subsonic-response":{"status":"ok","searchResult3":{"song":[{"id":"9","title":"Found"}]}}}
        """)).search("found")
        #expect(result.songs.map(\.title) == ["Found"])
        #expect(result.albums.isEmpty)
    }

    @Test("reads a song Octo found for a search as one to play from that server")
    func octoFind() async throws {
        // As Octo sends a song it found rather than one in the library: an id shaped like
        // Navidrome's, estimated size and bit rate, and the song's own id as its cover.
        let result = try await SubsonicClient(server: server, password: "x", transport: StubTransport(body: """
        {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","openSubsonic":true,"searchResult3":{"song":[
        {"id":"4hT9xQbZ2mLr8VnC1kPw0a","parent":"7gH2kL9mN4pQ6rS8tU0vWx","isDir":false,"title":"Night Drive","album":"Night Drive",
        "artist":"Mara Solis","track":1,"genre":"","coverArt":"4hT9xQbZ2mLr8VnC1kPw0a","size":2880000,"contentType":"audio/mp4",
        "suffix":"m4a","duration":180,"bitRate":128,"albumId":"7gH2kL9mN4pQ6rS8tU0vWx","artistId":"3aB5cD7eF9gH1iJ3kL5mN7",
        "type":"music","samplingRate":44100,"bitDepth":16,"displayAlbumArtist":"Mara Solis","replayGain":{},"isExternal":false}
        ]}}}
        """)).search("night drive", artists: 0, albums: 0, songs: 40)
        let song = try #require(result.songs.first)
        let track = song.track(on: "home")
        #expect(track.origin == .server(serverID: "home", songID: "4hT9xQbZ2mLr8VnC1kPw0a"))
        #expect(track.artwork == .server(serverID: "home", coverID: "4hT9xQbZ2mLr8VnC1kPw0a"))
        #expect(track.identity == HistoryImport.key(title: "Night Drive", artistName: "Mara Solis"))
    }
}

@Suite("Your library")
struct LocalLibraryTests {
    func track(_ title: String, artist: String = "Mara Solis", album: String? = "Coastlines", number: Int? = nil, disc: Int? = nil, path: String? = nil, server: Bool = false, genre: String? = nil) -> LocalTrack {
        LocalTrack(
            origin: server ? .server(serverID: "home", songID: title) : .file(path: path ?? "\(title).flac"),
            title: title,
            artist: artist,
            album: album,
            trackNumber: number,
            discNumber: disc,
            genre: genre
        )
    }

    @Test("an album's songs go disc by disc, in track order, untagged ones last")
    func albumOrder() {
        let index = LocalLibraryIndex(tracks: [
            track("C", number: 1, disc: 2), track("B", number: 2), track("Untagged"), track("A", number: 1),
        ])
        #expect(index.albums.count == 1)
        #expect(index.albums[0].tracks.map(\.title) == ["A", "B", "Untagged", "C"])
    }

    @Test("albums group however their tags are cased, and by album artist")
    func grouping() {
        let index = LocalLibraryIndex(tracks: [
            track("One", album: "Coastlines"),
            track("Two", artist: "MARA SOLIS", album: "coastlines"),
            track("Three", artist: "Guest", album: "Coastlines"),
        ])
        // The guest's song has its own artist, so its own album, unless album artist says so.
        #expect(index.albums.count == 2)
        var guest = track("Three", artist: "Guest", album: "Coastlines")
        guest.albumArtist = "Mara Solis"
        #expect(LocalLibraryIndex(tracks: [track("One"), guest]).albums.count == 1)
    }

    @Test("a song with a featured artist stays on its album, unless its tags say otherwise")
    func featured() {
        let index = LocalLibraryIndex(tracks: [
            track("One", artist: "Umbra", album: "Eclipse"),
            track("Two", artist: "Umbra feat. Yuki Tanabe", album: "Eclipse"),
            track("Three", artist: "Umbra (Feat. Mara Solis)", album: "Eclipse"),
            track("Four", artist: "Umbra ft. Nova Harbor", album: "Eclipse"),
        ])
        #expect(index.albums.count == 1)
        #expect(index.albums[0].artist == "Umbra")
        #expect(index.artists.map(\.name) == ["Umbra"])
        // The song keeps its own artist for the history.
        #expect(index.albums[0].tracks.contains { $0.artist == "Umbra feat. Yuki Tanabe" })
        #expect(LocalTrack.leadArtist(of: "Featherweight") == "Featherweight")
        #expect(LocalTrack.leadArtist(of: "Crosby, Stills & Nash") == "Crosby, Stills & Nash")
    }

    @Test("a name that grows when lowercased is cut at its own marker", arguments: [
        ("İSMAİL YK feat. Nova Harbor", "İSMAİL YK"),
        ("ȺȺȺȺȺȺȺȺ ft. X", "ȺȺȺȺȺȺȺȺ"),
        ("İİİİİİİİİİİİ FEAT. Y", "İİİİİİİİİİİİ"),
    ])
    func leadArtistKeepsItsLength(artist: String, lead: String) {
        #expect(LocalTrack.leadArtist(of: artist) == lead)
    }

    @Test("a song credits each artist on it by their whole name")
    func credits() {
        #expect(LocalTrack.creditedArtists(of: "Umbra feat. Yuki Tanabe & Mara Solis").isSuperset(of: ["umbra", "yuki tanabe", "mara solis"]))
        #expect(LocalTrack.creditedArtists(of: "Nova Harbor (feat. Air)").contains("air"))
        #expect(!LocalTrack.creditedArtists(of: "Blair").contains("air"))
        // A band with "&" in its name is still found whole.
        #expect(LocalTrack.creditedArtists(of: "Fern & Fable").contains("fern & fable"))
    }

    @Test("a history song is found by id, then by name, a file before a server's copy")
    func matching() {
        let file = track("Night Drive")
        let copy = track("Night Drive", server: true)
        let index = LocalLibraryIndex(tracks: [copy, file])
        #expect(index.track(forSongID: copy.id, identity: copy.identity) == copy)
        #expect(index.track(forSongID: "1440833098", identity: file.identity) == file)
        #expect(index.track(forSongID: "x", identity: "nothing") == nil)
    }

    @Test("every copy of a song is found by name, however it's cased")
    func copies() {
        let file = track("Night Drive")
        let copy = track("Night Drive", server: true)
        let index = LocalLibraryIndex(tracks: [file, copy, track("Tidal")])
        #expect(Set(index.tracks(withIdentity: HistoryImport.key(title: "night drive", artistName: "MARA SOLIS"))) == [file, copy])
        #expect(index.tracks(withIdentity: "nothing").isEmpty)
    }

    @Test("a server's search keeps only songs that aren't yours already, each once, in its order")
    func notIncluded() {
        let index = LocalLibraryIndex(tracks: [track("Night Drive"), track("Tidal", server: true)])
        let found = [
            track("Tidal", server: true),       // the same server song
            track("Night Drive", server: true), // a server's copy of a file you have
            track("Undertow", server: true),
            track("Harbor Lights", server: true),
            track("Undertow", artist: "Mara Solis", album: nil, path: "elsewhere", server: false),
        ]
        #expect(index.notIncluded(found).map(\.title) == ["Undertow", "Harbor Lights"])
        #expect(LocalLibraryIndex.empty.notIncluded([]).isEmpty)
    }

    @Test("search matches every word, across title, artist and album, without accents")
    func search() {
        let index = LocalLibraryIndex(tracks: [track("Café Night"), track("Morning", artist: "Nova Harbor", album: "Tides")])
        #expect(index.search("cafe mara").tracks.map(\.title) == ["Café Night"])
        #expect(index.search("tides").albums.map(\.title) == ["Tides"])
        #expect(index.search("nova").artists.map(\.name) == ["Nova Harbor"])
        #expect(index.search("   ").tracks.isEmpty)
    }

    @Test("Tracks Radio from your files weighs what you play, and offers the rest as new finds")
    func localRadio() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let played = track("Played")
        let plays = (0..<10).map {
            CaptureStat(songKey: "p\($0)", songID: "p", title: "Played", artistName: "Mara Solis", capturedAt: now.addingTimeInterval(-Double($0 + 1) * 86_400))
        }
        let mix = LiveMix.tracksRadio(from: [played, track("Never Heard"), track("Played", server: true)], history: ListeningHistory(plays), now: now, seed: 1)
        #expect(mix.candidates.count == 2)
        #expect(mix.candidates.first { $0.song.title == "Played" }?.isNew == false)
        #expect(mix.candidates.first { $0.song.title == "Played" }?.song.songID == played.id)
        #expect(mix.candidates.first { $0.song.title == "Never Heard" }?.isNew == true)
    }

    @Test("a mood from your files takes the songs whose genre suits it")
    func localMood() {
        let mix = LiveMix.mood(.chill, from: [track("Calm", genre: "Ambient"), track("Loud", genre: "Metal"), track("None")], history: ListeningHistory([]), seed: 1)
        #expect(mix.candidates.map(\.song.title) == ["Calm"])
    }

    @Test("a mood takes songs found for it as they are, as new finds, genre or not")
    func localMoodWithFinds() {
        let found = track("Found", server: true)
        let mix = LiveMix.mood(.chill, from: [track("Calm", genre: "Ambient"), track("Loud", genre: "Metal")], finds: [found], history: ListeningHistory([]), seed: 1)
        #expect(Set(mix.candidates.map(\.song.title)) == ["Calm", "Found"])
        #expect(mix.candidates.first { $0.song.title == "Found" }?.isNew == true)
    }

    @Test("formats describe themselves")
    func formats() {
        #expect(AudioFormat(codec: "MP3", bitRate: 320).detail == "320 kbps")
        #expect(AudioFormat(codec: "FLAC", sampleRate: 192_000, bitDepth: 24).isHiRes)
        #expect(AudioFormat.codec(forExtension: "AIFF") == "AIFF")
    }
}

@Suite("Pushed now playing")
struct PushedNowPlayingSourceTests {
    @Test("hands on what's published, and what was already playing when it starts")
    func publishes() async {
        let source = PushedNowPlayingSource()
        source.publish(NowPlayingObservation(title: "First", artistName: "A"))
        let stream = source.start()
        source.publish(NowPlayingObservation(title: "Second", artistName: "A"))
        source.stop()
        var titles: [String] = []
        for await observation in stream { titles.append(observation.title) }
        #expect(titles == ["First", "Second"])
        #expect(source.current?.title == "Second")
    }
}

@Suite("Your library, searched and arranged")
struct LocalLibraryArrangementTests {
    func track(_ title: String, artist: String = "Mara Solis", album: String? = "Coastlines", number: Int? = nil, disc: Int? = nil, duration: TimeInterval? = 200) -> LocalTrack {
        LocalTrack(
            origin: .file(path: "\(artist)/\(album ?? "")/\(title).flac"),
            title: title,
            artist: artist,
            album: album,
            trackNumber: number,
            discNumber: disc,
            duration: duration
        )
    }

    @Test("the best matches come first: the same name, then one starting with it, then a word")
    func ranking() {
        let index = LocalLibraryIndex(tracks: [
            track("Afterglow Harbor"),
            track("Harbor"),
            track("Northern Harbor Lights"),
            track("Harbored"),
            track("Tides", artist: "Harbor Lights", album: "Night Ferry"),
        ])
        #expect(index.search("harbor").tracks.map(\.title) == ["Harbor", "Harbored", "Afterglow Harbor", "Northern Harbor Lights", "Tides"])
    }

    @Test("an artist named just what was typed comes before one that merely starts with it")
    func artistRanking() {
        let index = LocalLibraryIndex(tracks: [track("One", artist: "Umbra Collective"), track("Two", artist: "Umbra")])
        #expect(index.search("umbra").artists.map(\.name) == ["Umbra", "Umbra Collective"])
    }

    @Test("albums and artists are found by their id")
    func lookups() {
        let index = LocalLibraryIndex(tracks: [track("One"), track("Two", artist: "Nova Harbor", album: "Tides")])
        let album = index.albums.first { $0.title == "Tides" }
        #expect(album != nil)
        #expect(index.album(id: album?.id ?? "") == album)
        #expect(index.artist(id: "nova harbor")?.name == "Nova Harbor")
        #expect(index.album(id: "nothing") == nil)
    }

    @Test("a multi-disc album is split into its discs, in order")
    func discs() {
        let index = LocalLibraryIndex(tracks: [
            track("C", number: 1, disc: 2), track("B", number: 2, disc: 1), track("A", number: 1, disc: 1), track("D", number: 2, disc: 2),
        ])
        let discs = index.albums[0].discs
        #expect(discs.map(\.number) == [1, 2])
        #expect(discs.map { $0.tracks.map(\.title) } == [["A", "B"], ["C", "D"]])
        #expect(LocalLibraryIndex(tracks: [track("Only")]).albums[0].discs.map(\.number) == [1])
    }

    @Test("a short release is a single or an EP, by its title or its length", arguments: [
        (["One"], 200.0, "Coastlines", LocalAlbum.Kind.single),
        (["One", "Two", "Three", "Four", "Five"], 200.0, "Coastlines", .ep),
        (["One", "Two", "Three", "Four", "Five", "Six", "Seven"], 200.0, "Coastlines", .album),
        (["One", "Two"], 1000.0, "Coastlines", .album),
        (["One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight"], 200.0, "Coastlines - EP", .ep),
        (["One"], 200.0, "Coastlines - Single", .single),
    ])
    func kinds(titles: [String], duration: Double, album: String, kind: LocalAlbum.Kind) {
        let index = LocalLibraryIndex(tracks: titles.map { track($0, album: album, duration: duration) })
        #expect(index.albums[0].kind == kind)
        #expect(index.albums[0].displayTitle == "Coastlines")
    }

    @Test("an artist appears on others' albums they're credited on, by whole name")
    func appearsOn() {
        let index = LocalLibraryIndex(tracks: [
            track("One", artist: "Air", album: "Moon"),
            track("Two", artist: "Blair", album: "Dusk"),
            track("Three", artist: "Nova Harbor feat. Air", album: "Tides"),
        ])
        #expect(index.albums(appearingOn: "air").map(\.title) == ["Tides"])
    }

    @Test("a release whose songs have no lengths is taken for an album")
    func unknownLengths() {
        let index = LocalLibraryIndex(tracks: [track("One", duration: nil)])
        #expect(index.albums[0].kind == .album)
    }
}

import Foundation
import CryptoKit

/// A music server that speaks the Subsonic API, the standard self-hosted music servers share:
/// Navidrome, Gonic, Airsonic, Ampache, LMS and others. OpenSubsonic, its open extension,
/// is spoken by most of them today.
public struct SubsonicServer: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var name: String
    public var url: URL
    public var username: String
    /// Mixed into the password for the token cover addresses carry, so the password itself
    /// never goes over the wire. Fixed per server, so those addresses stay the same between
    /// launches and their images stay cached. Every other request gets a salt of its own.
    public var salt: String

    public init(id: String = UUID().uuidString, name: String, url: URL, username: String, salt: String = SubsonicServer.makeSalt()) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.salt = salt
    }

    public static func makeSalt() -> String {
        String((0..<12).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }

    /// An address as someone types it: "192.168.1.20:4533" gains http, "music.example.com"
    /// gains https, a trailing slash goes. See ``ServerAddress``.
    public static func address(from text: String) -> URL? {
        ServerAddress.url(from: text)
    }
}

/// Why a server said no.
public enum SubsonicError: Error, Equatable, Sendable {
    /// Username or password wrong (Subsonic codes 40 and 41).
    case wrongCredentials
    /// The server is too old for what was asked (codes 20 and 30).
    case incompatible
    /// Not found (code 70).
    case notFound
    case server(code: Int, message: String)
    /// Not a Subsonic answer at all: the wrong address, most likely.
    case notSubsonic
    case http(status: Int)
}

/// Sends a request and hands back the body. URLSession in the app; a stub in the tests.
public protocol SubsonicTransport: Sendable {
    func data(for url: URL) async throws -> (Data, Int)
}

public struct URLSessionTransport: SubsonicTransport {
    public init() {}

    public func data(for url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
    }
}

/// Talks to one Subsonic server.
public struct SubsonicClient: Sendable {
    public let server: SubsonicServer
    /// Kept to sign each request with a fresh salt. Only its salted hash leaves the device.
    private let password: String
    private let transport: any SubsonicTransport

    /// The API version asked for. 1.16.1 is the last Subsonic release; OpenSubsonic servers
    /// answer to it too.
    static let apiVersion = "1.16.1"

    public init(server: SubsonicServer, password: String, transport: any SubsonicTransport = URLSessionTransport()) {
        self.server = server
        self.password = password
        self.transport = transport
    }

    /// md5(password + salt), in lower-case hex, as the API asks.
    static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Addresses

    /// An endpoint's address with the credentials every request carries, signed with a salt
    /// of its own. With one salt for good, the token in any address that reached a log
    /// would sign every request after it.
    public func url(_ endpoint: String, _ parameters: [String: String] = [:], json: Bool = true) -> URL {
        url(endpoint, parameters, json: json, salt: SubsonicServer.makeSalt())
    }

    private func url(_ endpoint: String, _ parameters: [String: String], json: Bool, salt: String) -> URL {
        var components = URLComponents(url: server.url.appending(path: "rest/\(endpoint)"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "u", value: server.username),
            URLQueryItem(name: "t", value: Self.token(password: password, salt: salt)),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: "Tracks"),
        ]
        if json { items.append(URLQueryItem(name: "f", value: "json")) }
        items += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        // URLComponents leaves "+" alone, and servers read it as a space: "luke+music@example.com"
        // would sign in as someone else, and "Florence + the Machine" wouldn't be found.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    /// The song as the server stores it, or re-encoded to a bit rate for a slow connection.
    /// - Parameter maxBitRate: kilobits a second, or nil for the original file.
    public func streamURL(songID: String, maxBitRate: Int? = nil) -> URL {
        if let maxBitRate {
            return url("stream", ["id": songID, "maxBitRate": String(maxBitRate), "format": "mp3"], json: false)
        }
        return url("stream", ["id": songID, "format": "raw"], json: false)
    }

    /// The original file, for keeping.
    public func downloadURL(songID: String) -> URL {
        url("download", ["id": songID], json: false)
    }

    /// Signed with the server's own salt, so the address is the same every time and the
    /// image stays cached.
    public func coverArtURL(id: String, size: Int? = nil) -> URL {
        url("getCoverArt", size.map { ["id": id, "size": String($0)] } ?? ["id": id], json: false, salt: server.salt)
    }

    // MARK: - Asking

    /// Checks the address and credentials.
    public func ping() async throws {
        _ = try await call("ping")
    }

    /// Every artist on the server.
    public func artists() async throws -> [SubsonicArtist] {
        let body = try await call("getArtists")
        return (body.artists?.index ?? []).flatMap { $0.artist ?? [] }
    }

    public func artist(id: String) async throws -> (artist: SubsonicArtist, albums: [SubsonicAlbum]) {
        let body = try await call("getArtist", ["id": id])
        guard let artist = body.artist else { throw SubsonicError.notFound }
        return (artist.artist, artist.album ?? [])
    }

    public func album(id: String) async throws -> (album: SubsonicAlbum, songs: [SubsonicSong]) {
        let body = try await call("getAlbum", ["id": id])
        guard let album = body.album else { throw SubsonicError.notFound }
        return (album.album, album.song ?? [])
    }

    public enum AlbumListType: String, Sendable, CaseIterable {
        case newest, recent, frequent, random, highest, alphabeticalByName, starred
    }

    public func albums(_ type: AlbumListType, size: Int = 30, offset: Int = 0) async throws -> [SubsonicAlbum] {
        let body = try await call("getAlbumList2", ["type": type.rawValue, "size": String(size), "offset": String(offset)])
        return body.albumList2?.album ?? []
    }

    /// Artists, albums and songs matching a query. An empty query matches everything, which
    /// is how a whole library is paged through.
    public func search(_ query: String, artists: Int = 10, albums: Int = 20, songs: Int = 40, songOffset: Int = 0) async throws -> SubsonicSearchResult {
        let body = try await call("search3", [
            "query": query,
            "artistCount": String(artists),
            "albumCount": String(albums),
            "songCount": String(songs),
            "songOffset": String(songOffset),
        ])
        let result = body.searchResult3
        return SubsonicSearchResult(artists: result?.artist ?? [], albums: result?.album ?? [], songs: result?.song ?? [])
    }

    /// Songs like an artist's, or like a song, from across the server. Needs the server to
    /// know about similar artists, which most get from Last.fm.
    public func similarSongs(to id: String, count: Int = 50) async throws -> [SubsonicSong] {
        let body = try await call("getSimilarSongs2", ["id": id, "count": String(count)])
        return body.similarSongs2?.song ?? []
    }

    public func topSongs(artist name: String, count: Int = 20) async throws -> [SubsonicSong] {
        let body = try await call("getTopSongs", ["artist": name, "count": String(count)])
        return body.topSongs?.song ?? []
    }

    /// Artists like this one that the server has.
    public func similarArtists(to id: String, count: Int = 20) async throws -> [SubsonicArtist] {
        let body = try await call("getArtistInfo2", ["id": id, "count": String(count)])
        return body.artistInfo2?.similarArtist ?? []
    }

    public func randomSongs(count: Int = 30, genre: String? = nil) async throws -> [SubsonicSong] {
        var parameters = ["size": String(count)]
        if let genre { parameters["genre"] = genre }
        let body = try await call("getRandomSongs", parameters)
        return body.randomSongs?.song ?? []
    }

    /// Tells the server a song played, for its own counts and anything it passes plays on to.
    /// - Parameter submission: false while it starts ("now playing"), true once it counts.
    public func scrobble(songID: String, at date: Date = .now, submission: Bool) async throws {
        _ = try await call("scrobble", [
            "id": songID,
            "time": String(Int(date.timeIntervalSince1970 * 1_000)),
            "submission": submission ? "true" : "false",
        ])
    }

    public func star(songID: String) async throws {
        _ = try await call("star", ["id": songID])
    }

    public func unstar(songID: String) async throws {
        _ = try await call("unstar", ["id": songID])
    }

    private func call(_ endpoint: String, _ parameters: [String: String] = [:]) async throws -> SubsonicResponse.Body {
        let (data, status) = try await transport.data(for: url(endpoint, parameters))
        return try Self.decode(data, status: status)
    }

    static func decode(_ data: Data, status: Int) throws -> SubsonicResponse.Body {
        guard let response = try? JSONDecoder().decode(SubsonicResponse.self, from: data) else {
            throw (200..<300).contains(status) ? SubsonicError.notSubsonic : SubsonicError.http(status: status)
        }
        let body = response.body
        guard body.status == "ok" else {
            let code = body.error?.code ?? 0
            switch code {
            case 40, 41: throw SubsonicError.wrongCredentials
            case 20, 30: throw SubsonicError.incompatible
            case 70: throw SubsonicError.notFound
            default: throw SubsonicError.server(code: code, message: body.error?.message ?? "")
            }
        }
        return body
    }
}

// MARK: - What the server sends

public struct SubsonicArtist: Codable, Sendable, Hashable, Identifiable {
    @Lenient public var id: String
    public var name: String
    public var albumCount: Int?
    public var coverArt: String?
    public var artistImageUrl: String?

    public init(id: String, name: String, albumCount: Int? = nil, coverArt: String? = nil) {
        self._id = Lenient(wrappedValue: id)
        self.name = name
        self.albumCount = albumCount
        self.coverArt = coverArt
    }
}

public struct SubsonicAlbum: Codable, Sendable, Hashable, Identifiable {
    @Lenient public var id: String
    public var name: String
    public var artist: String?
    @LenientOptional public var artistId: String?
    public var coverArt: String?
    public var songCount: Int?
    public var duration: Int?
    public var year: Int?
    public var genre: String?
    public var created: String?

    public init(id: String, name: String, artist: String? = nil, artistId: String? = nil, coverArt: String? = nil, songCount: Int? = nil, year: Int? = nil, genre: String? = nil) {
        self._id = Lenient(wrappedValue: id)
        self.name = name
        self.artist = artist
        self._artistId = LenientOptional(wrappedValue: artistId)
        self.coverArt = coverArt
        self.songCount = songCount
        self.year = year
        self.genre = genre
    }
}

public struct SubsonicSong: Codable, Sendable, Hashable, Identifiable {
    @Lenient public var id: String
    public var title: String
    public var artist: String?
    public var album: String?
    @LenientOptional public var albumId: String?
    @LenientOptional public var artistId: String?
    public var track: Int?
    public var discNumber: Int?
    public var year: Int?
    public var genre: String?
    public var duration: Int?
    public var suffix: String?
    public var contentType: String?
    public var bitRate: Int?
    public var size: Int?
    public var coverArt: String?
    /// OpenSubsonic: the file's own sample rate and bit depth.
    public var samplingRate: Int?
    public var bitDepth: Int?
    /// OpenSubsonic: the album's artist, where the server knows it.
    public var displayAlbumArtist: String?
    /// Octo: a song it found for you rather than one in the library.
    public var isExternal: Bool?
    /// When the server added the song, as ISO 8601: "2024-03-01T18:22:10.000Z".
    public var created: String?

    /// When the server added the song, where it says.
    public var createdDate: Date? {
        guard let created else { return nil }
        if let date = try? Date(created, strategy: .iso8601) { return date }
        // Without fractional seconds, or without a zone, as some servers send it.
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? Date(created, strategy: withFraction) { return date }
        return try? Date(created + "Z", strategy: .iso8601)
    }

    public init(id: String, title: String, artist: String? = nil, album: String? = nil, albumId: String? = nil, track: Int? = nil, duration: Int? = nil, suffix: String? = nil, coverArt: String? = nil) {
        self._id = Lenient(wrappedValue: id)
        self.title = title
        self.artist = artist
        self.album = album
        self._albumId = LenientOptional(wrappedValue: albumId)
        self._artistId = LenientOptional(wrappedValue: nil)
        self.track = track
        self.duration = duration
        self.suffix = suffix
        self.coverArt = coverArt
    }

    /// The song as one of your own, on this server.
    public func track(on serverID: String, addedAt: Date = .now) -> LocalTrack {
        LocalTrack(
            origin: .server(serverID: serverID, songID: id),
            title: title,
            artist: artist ?? "",
            albumArtist: displayAlbumArtist,
            album: album,
            trackNumber: track,
            discNumber: discNumber,
            year: year,
            genre: genre,
            duration: duration.map(TimeInterval.init),
            format: suffix.map {
                AudioFormat(codec: AudioFormat.codec(forExtension: $0), sampleRate: samplingRate, bitDepth: bitDepth, bitRate: bitRate)
            },
            artwork: coverArt.map { .server(serverID: serverID, coverID: $0) },
            addedAt: addedAt
        )
    }
}

public struct SubsonicSearchResult: Sendable, Equatable {
    public var artists: [SubsonicArtist]
    public var albums: [SubsonicAlbum]
    public var songs: [SubsonicSong]
}

/// The envelope every answer comes in: `{"subsonic-response": {...}}`.
struct SubsonicResponse: Decodable {
    let body: Body

    enum CodingKeys: String, CodingKey {
        case body = "subsonic-response"
    }

    struct Body: Decodable {
        let status: String
        let error: ErrorBody?
        let artists: ArtistsIndex?
        let artist: ArtistWithAlbums?
        let album: AlbumWithSongs?
        let albumList2: AlbumList?
        let searchResult3: SearchResult?
        let similarSongs2: SongList?
        let topSongs: SongList?
        let randomSongs: SongList?
        let artistInfo2: ArtistInfo?
    }

    struct ErrorBody: Decodable {
        let code: Int
        let message: String?
    }

    struct ArtistsIndex: Decodable {
        let index: [Index]?
        struct Index: Decodable { let artist: [SubsonicArtist]? }
    }

    struct ArtistWithAlbums: Decodable {
        let artist: SubsonicArtist
        let album: [SubsonicAlbum]?

        init(from decoder: any Decoder) throws {
            artist = try SubsonicArtist(from: decoder)
            album = try decoder.container(keyedBy: Keys.self).decodeIfPresent([SubsonicAlbum].self, forKey: .album)
        }

        enum Keys: String, CodingKey { case album }
    }

    struct AlbumWithSongs: Decodable {
        let album: SubsonicAlbum
        let song: [SubsonicSong]?

        init(from decoder: any Decoder) throws {
            album = try SubsonicAlbum(from: decoder)
            song = try decoder.container(keyedBy: Keys.self).decodeIfPresent([SubsonicSong].self, forKey: .song)
        }

        enum Keys: String, CodingKey { case song }
    }

    struct AlbumList: Decodable { let album: [SubsonicAlbum]? }
    struct SongList: Decodable { let song: [SubsonicSong]? }
    struct SearchResult: Decodable {
        let artist: [SubsonicArtist]?
        let album: [SubsonicAlbum]?
        let song: [SubsonicSong]?
    }
    struct ArtistInfo: Decodable { let similarArtist: [SubsonicArtist]? }
}

/// An id some servers send as a number and others as a string.
@propertyWrapper
public struct Lenient: Codable, Sendable, Hashable {
    public var wrappedValue: String

    public init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            wrappedValue = text
        } else {
            wrappedValue = String(try container.decode(Int.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// ``Lenient``, for an id that may be missing.
@propertyWrapper
public struct LenientOptional: Codable, Sendable, Hashable {
    public var wrappedValue: String?

    public init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else if let text = try? container.decode(String.self) {
            wrappedValue = text
        } else {
            wrappedValue = (try? container.decode(Int.self)).map(String.init)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// A missing optional id decodes as nil rather than failing the whole item.
    public func decode(_ type: LenientOptional.Type, forKey key: Key) throws -> LenientOptional {
        try decodeIfPresent(type, forKey: key) ?? LenientOptional(wrappedValue: nil)
    }
}

import Foundation

/// Lidarr, which looks after a music collection: it follows artists, finds their albums as
/// they come out, and files them into the library a music server plays from.
///
/// Tracks talks to its v1 API to add artists, ask for albums and show what's on its way.
public struct LidarrServer: Codable, Sendable, Hashable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    /// An address as someone types it: "192.168.1.20:8686" gains http, "lidarr.example.com"
    /// gains https, a trailing slash goes. See ``ServerAddress``.
    public static func address(from text: String) -> URL? {
        ServerAddress.url(from: text)
    }
}

public enum LidarrError: Error, Equatable, Sendable {
    /// The API key was refused (401).
    case wrongKey
    /// Lidarr said why it wouldn't: "This artist has already been added".
    case rejected(String)
    /// Not Lidarr at all: the wrong address or port, most likely.
    case notLidarr
    case http(status: Int)
}

/// Sends a request and hands back the body and status. URLSession in the app; a stub in tests.
public protocol LidarrTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionLidarrTransport: LidarrTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
    }
}

public struct LidarrClient: Sendable {
    public let server: LidarrServer
    private let apiKey: String
    private let transport: any LidarrTransport

    public init(server: LidarrServer, apiKey: String, transport: any LidarrTransport = URLSessionLidarrTransport()) {
        self.server = server
        self.apiKey = apiKey
        self.transport = transport
    }

    // MARK: - Asking

    public func status() async throws -> LidarrStatus {
        try await get("system/status")
    }

    public func qualityProfiles() async throws -> [LidarrProfile] {
        try await get("qualityprofile")
    }

    public func metadataProfiles() async throws -> [LidarrProfile] {
        try await get("metadataprofile")
    }

    public func rootFolders() async throws -> [LidarrRootFolder] {
        try await get("rootfolder")
    }

    /// Every artist Lidarr follows.
    public func artists() async throws -> [LidarrArtist] {
        try await get("artist")
    }

    /// Artists by name, from MusicBrainz, as Lidarr's own search finds them.
    public func lookUpArtists(_ term: String) async throws -> [LidarrArtist] {
        try await get("artist/lookup", ["term": term])
    }

    /// Adds an artist to follow, with what to follow and where to file it.
    public func add(_ artist: LidarrArtist, options: LidarrAddOptions) async throws -> LidarrArtist {
        let body = AddArtist(
            artistName: artist.artistName,
            foreignArtistId: artist.foreignArtistId,
            qualityProfileId: options.qualityProfileID,
            metadataProfileId: options.metadataProfileID,
            rootFolderPath: options.rootFolderPath,
            monitored: true,
            monitorNewItems: options.monitor.followsNewAlbums ? "all" : "none",
            addOptions: .init(monitor: options.monitor.rawValue, searchForMissingAlbums: options.searchNow)
        )
        return try await send("artist", method: "POST", body: body)
    }

    public func albums(ofArtist artistID: Int) async throws -> [LidarrAlbum] {
        try await get("album", ["artistId": String(artistID)])
    }

    /// Every album Lidarr knows, filed or not, in one request.
    public func albums() async throws -> [LidarrAlbum] {
        try await get("album", [:])
    }

    /// Follows or stops following albums.
    public func setMonitored(_ albumIDs: [Int], _ monitored: Bool) async throws {
        try await perform("album/monitor", method: "PUT", body: Monitor(albumIds: albumIDs, monitored: monitored))
    }

    /// Asks Lidarr to go and find these albums now.
    public func search(albums albumIDs: [Int]) async throws {
        try await perform("command", method: "POST", body: CommandBody(name: "AlbumSearch", albumIds: albumIDs, artistId: nil))
    }

    /// Asks Lidarr to find everything missing by an artist.
    public func search(artist artistID: Int) async throws {
        try await perform("command", method: "POST", body: CommandBody(name: "ArtistSearch", albumIds: nil, artistId: artistID))
    }

    /// An album's tracks, each with whether Lidarr has its file.
    public func tracks(ofAlbum albumID: Int) async throws -> [LidarrTrack] {
        try await get("track", ["albumId": String(albumID)])
    }

    /// Every track of an artist's, in one request rather than one per album.
    public func tracks(ofArtist artistID: Int) async throws -> [LidarrTrack] {
        try await get("track", ["artistId": String(artistID)])
    }

    /// What's downloading or waiting to be filed.
    public func queue() async throws -> [LidarrQueueItem] {
        let page: LidarrPage<LidarrQueueItem> = try await get("queue", [
            "page": "1", "pageSize": "100", "includeArtist": "true", "includeAlbum": "true",
        ])
        return page.records
    }

    /// Albums Lidarr follows but doesn't have, newest first.
    public func missing() async throws -> [LidarrAlbum] {
        let page: LidarrPage<LidarrAlbum> = try await get("wanted/missing", [
            "page": "1", "pageSize": "100", "includeArtist": "true",
            "sortKey": "releaseDate", "sortDirection": "descending", "monitored": "true",
        ])
        return page.records
    }

    /// Albums coming out between two dates, by artists Lidarr follows.
    public func calendar(from start: Date, to end: Date) async throws -> [LidarrAlbum] {
        try await get("calendar", [
            "start": start.formatted(.iso8601),
            "end": end.formatted(.iso8601),
            "includeArtist": "true",
        ])
    }

    // MARK: - Requests

    func request(_ path: String, _ query: [String: String] = [:], method: String = "GET", body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: server.url.appending(path: "api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        // In a header, never the address, so the key isn't kept in logs or caches.
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.timeoutInterval = 20
        return request
    }

    private func get<Value: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> Value {
        try Self.decode(try await transport.send(request(path, query)))
    }

    private func send<Body: Encodable, Value: Decodable>(_ path: String, method: String, body: Body) async throws -> Value {
        let data = try JSONEncoder().encode(body)
        return try Self.decode(try await transport.send(request(path, method: method, body: data)))
    }

    /// For requests whose answer doesn't matter, only whether Lidarr took them: some answer
    /// with nothing at all.
    private func perform<Body: Encodable>(_ path: String, method: String, body: Body) async throws {
        let data = try JSONEncoder().encode(body)
        let response = try await transport.send(request(path, method: method, body: data))
        try Self.check(response)
    }

    static func check(_ response: (Data, Int)) throws {
        let (data, status) = response
        if status == 401 { throw LidarrError.wrongKey }
        guard (200..<300).contains(status) else {
            // Lidarr explains a refusal as a list of problems, each with a message.
            if let problems = try? JSONDecoder().decode([Problem].self, from: data), let first = problems.first {
                throw LidarrError.rejected(first.errorMessage)
            }
            throw LidarrError.http(status: status)
        }
    }

    static func decode<Value: Decodable>(_ response: (Data, Int)) throws -> Value {
        try check(response)
        do {
            return try LidarrClient.decoder.decode(Value.self, from: response.0)
        } catch {
            throw LidarrError.notLidarr
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }()

    private struct Problem: Decodable { let errorMessage: String }

    private struct AddArtist: Encodable {
        let artistName: String
        let foreignArtistId: String
        let qualityProfileId: Int
        let metadataProfileId: Int
        let rootFolderPath: String
        let monitored: Bool
        let monitorNewItems: String
        let addOptions: AddOptions

        struct AddOptions: Encodable {
            let monitor: String
            let searchForMissingAlbums: Bool
        }
    }

    private struct Monitor: Encodable {
        let albumIds: [Int]
        let monitored: Bool
    }

    private struct CommandBody: Encodable {
        let name: String
        let albumIds: [Int]?
        let artistId: Int?
    }

}

// MARK: - What Lidarr sends

public struct LidarrStatus: Decodable, Sendable, Equatable {
    public let version: String
    public let appName: String?
}

public struct LidarrProfile: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public struct LidarrRootFolder: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let path: String
    public let freeSpace: Int64?
}

public struct LidarrImage: Codable, Sendable, Hashable {
    public let coverType: String
    public let url: String?
    /// Where the picture comes from, outside Lidarr: loads without Lidarr's key.
    public let remoteUrl: String?
}

public struct LidarrStatistics: Codable, Sendable, Hashable {
    public let albumCount: Int?
    public let trackFileCount: Int?
    public let trackCount: Int?
    public let totalTrackCount: Int?
    public let sizeOnDisk: Int64?
    public let percentOfTracks: Double?
}

public struct LidarrArtist: Codable, Sendable, Hashable, Identifiable {
    /// Nil for a search result Lidarr doesn't follow yet.
    public let id: Int?
    public let artistName: String
    public let foreignArtistId: String
    public let monitored: Bool?
    public let overview: String?
    public let disambiguation: String?
    public let genres: [String]?
    public let images: [LidarrImage]?
    public let statistics: LidarrStatistics?

    public init(id: Int? = nil, artistName: String, foreignArtistId: String, monitored: Bool? = nil, overview: String? = nil, disambiguation: String? = nil, genres: [String]? = nil, images: [LidarrImage]? = nil, statistics: LidarrStatistics? = nil) {
        self.id = id
        self.artistName = artistName
        self.foreignArtistId = foreignArtistId
        self.monitored = monitored
        self.overview = overview
        self.disambiguation = disambiguation
        self.genres = genres
        self.images = images
        self.statistics = statistics
    }

    /// The artist's picture, from outside Lidarr.
    public var pictureURL: URL? {
        let preferred = images?.first { $0.coverType == "poster" } ?? images?.first
        return preferred?.remoteUrl.flatMap(URL.init(string:))
    }
}

public struct LidarrAlbum: Codable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let albumType: String?
    public let releaseDate: Date?
    public let monitored: Bool?
    public let artistId: Int?
    public let foreignAlbumId: String?
    public let images: [LidarrImage]?
    public let statistics: LidarrStatistics?
    /// Included where asked for: the queue, Wanted and the calendar.
    public let artist: LidarrArtist?

    /// At least one of its songs is filed.
    public var hasFiles: Bool {
        (statistics?.trackFileCount ?? 0) > 0
    }

    /// Every track is filed.
    public var isComplete: Bool {
        guard let statistics, let total = statistics.totalTrackCount ?? statistics.trackCount, total > 0 else { return false }
        return (statistics.trackFileCount ?? 0) >= total
    }

    public var coverURL: URL? {
        let preferred = images?.first { $0.coverType == "cover" } ?? images?.first
        return preferred?.remoteUrl.flatMap(URL.init(string:))
    }
}

public struct LidarrTrack: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String
    public let hasFile: Bool
    public let trackNumber: String?
    public let albumId: Int?
}

public struct LidarrQueueItem: Decodable, Sendable, Hashable, Identifiable {
    public let id: Int
    public let title: String?
    /// "downloading", "queued", "paused", "completed", "failed" and the like.
    public let status: String?
    /// "downloading", "importPending", "importing", "imported", "failedPending"...
    public let trackedDownloadState: String?
    public let size: Double?
    public let sizeleft: Double?
    public let timeleft: String?
    public let errorMessage: String?
    public let album: LidarrAlbum?
    public let artist: LidarrArtist?

    /// How far through it is, from 0 to 1.
    public var progress: Double {
        guard let size, size > 0 else { return 0 }
        return min(1, max(0, (size - (sizeleft ?? size)) / size))
    }
}

struct LidarrPage<Record: Decodable & Sendable>: Decodable, Sendable {
    let records: [Record]
}

/// What Lidarr does when Tracks adds an artist.
public struct LidarrAddOptions: Sendable, Equatable {
    public enum Monitor: String, Sendable, CaseIterable {
        /// Every album, past and future.
        case all
        /// Only albums from now on.
        case future
        /// The newest album, and what comes after.
        case latest
        /// Nothing yet: albums are asked for one at a time.
        case none

        var followsNewAlbums: Bool { self != .none }
    }

    public var qualityProfileID: Int
    public var metadataProfileID: Int
    public var rootFolderPath: String
    public var monitor: Monitor
    /// Look for what's wanted straight away, rather than at Lidarr's next check.
    public var searchNow: Bool

    public init(qualityProfileID: Int, metadataProfileID: Int, rootFolderPath: String, monitor: Monitor, searchNow: Bool) {
        self.qualityProfileID = qualityProfileID
        self.metadataProfileID = metadataProfileID
        self.rootFolderPath = rootFolderPath
        self.monitor = monitor
        self.searchNow = searchNow
    }
}

extension LidarrClient {
    /// Finds the artist Lidarr already follows by this name, or looks them up and adds them.
    /// - Returns: the artist, and whether it was just added.
    public func follow(artistNamed name: String, options: LidarrAddOptions) async throws -> (artist: LidarrArtist, isNew: Bool) {
        let followed = try await artists()
        // "Drake & 21 Savage" is followed as Drake: a whole name first, then its first artist.
        for candidate in Self.artistCandidates(name) {
            let wanted = StatsCalculator.folded(candidate)
            if let existing = followed.first(where: { StatsCalculator.folded($0.artistName) == wanted }) {
                return (existing, false)
            }
            // Only an exact name: the first result for a name that isn't there is someone else.
            if let match = try await lookUpArtists(candidate).first(where: { StatsCalculator.folded($0.artistName) == wanted }) {
                return (try await add(match, options: options), true)
            }
        }
        throw LidarrError.rejected(String(localized: "Lidarr couldn't find an artist called \(name)."))
    }

    /// A credited name, then the first artist in it where several are credited.
    public static func artistCandidates(_ name: String) -> [String] {
        let lead = ArtistCredits.lead(of: name)
        return lead.isEmpty || lead == name ? [name] : [name, lead]
    }

    /// Asks for one album: the artist is followed if they aren't (without taking the rest of
    /// their albums), the album is followed, and Lidarr goes to find it.
    ///
    /// A newly added artist's albums take Lidarr a moment to fill in, so this waits for them.
    public func request(album title: String, by artistName: String, options: LidarrAddOptions, waitStep: Duration = .seconds(2), attempts: Int = 10) async throws -> LidarrAlbum {
        var quiet = options
        quiet.monitor = .none
        quiet.searchNow = false
        let (artist, _) = try await follow(artistNamed: artistName, options: quiet)
        guard let artistID = artist.id else { throw LidarrError.rejected(String(localized: "Lidarr couldn't add \(artistName).")) }
        for attempt in 0..<attempts {
            if let album = Self.match(title, in: try await albums(ofArtist: artistID)) {
                try await setMonitored([album.id], true)
                try await search(albums: [album.id])
                return album
            }
            if attempt < attempts - 1 { try await Task.sleep(for: waitStep) }
        }
        throw LidarrError.rejected(String(localized: "Lidarr doesn't know \u{201C}\(title)\u{201D} by \(artistName) yet."))
    }

    /// The album a title means: the same title, or the same once editions are set aside.
    /// Nothing looser: "Americana" isn't "America", and "folklore: the long pond studio
    /// sessions" isn't "folklore".
    public static func match(_ title: String, in albums: [LidarrAlbum]) -> LidarrAlbum? {
        let exact = StatsCalculator.folded(title)
        if let album = albums.first(where: { StatsCalculator.folded($0.title) == exact }) { return album }
        let key = albumKey(title)
        return albums.first { albumKey($0.title) == key }
    }

    /// An album's title for matching, less the edition Apple Music and servers add: "Coastlines
    /// (Deluxe Edition)" and "Coastlines - Single" are "coastlines". Anything else in brackets
    /// stays: "1989 (Taylor's Version)" is its own album.
    public static func albumKey(_ title: String) -> String {
        var key = StatsCalculator.folded(title).trimmingCharacters(in: .whitespaces)
        for suffix in [" - single", " - ep"] where key.hasSuffix(suffix) {
            key = String(key.dropLast(suffix.count))
        }
        let editions = ["deluxe", "remaster", "expanded", "anniversary", "bonus track", "special edition", "edition", "explicit", "clean", "mono", "stereo"]
        while let open = key.lastIndex(where: { $0 == "(" || $0 == "[" }), key.last == ")" || key.last == "]" {
            let inside = key[key.index(after: open)..<key.index(before: key.endIndex)]
            guard editions.contains(where: { inside.contains($0) }) else { break }
            key = String(key[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return key
    }
}

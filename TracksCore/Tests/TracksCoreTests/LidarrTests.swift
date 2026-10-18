import Testing
import Foundation
import Synchronization
@testable import TracksCore

/// A pretend Lidarr: answers by method and path, and remembers what it was asked.
private final class StubLidarr: LidarrTransport {
    typealias Handler = @Sendable (URLRequest) -> (String, Int)
    private let routes: [String: Handler]
    private let log = Mutex<[URLRequest]>([])

    init(_ routes: [String: Handler]) {
        self.routes = routes
    }

    var requests: [URLRequest] { log.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        log.withLock { $0.append(request) }
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path())"
        guard let handler = routes[key] else { return (Data("[]".utf8), 404) }
        let (body, status) = handler(request)
        return (Data(body.utf8), status)
    }
}

private func json(_ text: String, _ status: Int = 200) -> StubLidarr.Handler {
    { _ in (text, status) }
}

@Suite("Lidarr")
struct LidarrTests {
    let server = LidarrServer(url: URL(string: "http://192.168.1.20:8686")!)
    let options = LidarrAddOptions(qualityProfileID: 1, metadataProfileID: 2, rootFolderPath: "/music", monitor: .all, searchNow: true)

    @Test("an address is tidied as it's typed, http by default")
    func address() {
        #expect(LidarrServer.address(from: "192.168.1.20:8686/")?.absoluteString == "http://192.168.1.20:8686")
        #expect(LidarrServer.address(from: "https://lidarr.example.com")?.absoluteString == "https://lidarr.example.com")
        #expect(LidarrServer.address(from: " ") == nil)
    }

    @Test("the API key goes in a header, never the address")
    func key() {
        let request = LidarrClient(server: server, apiKey: "secret").request("artist/lookup", ["term": "Florence + the Machine"])
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "secret")
        #expect(request.url?.path() == "/api/v1/artist/lookup")
        #expect(!(request.url?.absoluteString.contains("secret") ?? true))
        #expect(request.url?.query(percentEncoded: true)?.contains("%2B") == true)
    }

    @Test("reads albums, with their dates, statistics and covers")
    func albums() async throws {
        let stub = StubLidarr(["GET /api/v1/album": json("""
        [{"id":7,"title":"Coastlines","albumType":"Album","releaseDate":"2019-05-17T00:00:00Z","monitored":true,"artistId":3,
          "images":[{"coverType":"cover","url":"/MediaCover/7/cover.jpg","remoteUrl":"https://coverartarchive.org/7.jpg"}],
          "statistics":{"trackFileCount":9,"trackCount":9,"totalTrackCount":9,"sizeOnDisk":400000000,"percentOfTracks":100}},
         {"id":8,"title":"Next","releaseDate":"2026-10-03T00:00:00.000Z","statistics":{"trackFileCount":0,"trackCount":10}}]
        """)])
        let albums = try await LidarrClient(server: server, apiKey: "k", transport: stub).albums(ofArtist: 3)
        #expect(albums.map(\.title) == ["Coastlines", "Next"])
        #expect(albums[0].isComplete)
        #expect(!albums[1].isComplete)
        #expect(albums[0].coverURL?.host() == "coverartarchive.org")
        #expect(Calendar(identifier: .gregorian).component(.year, from: try #require(albums[1].releaseDate)) == 2026)
        #expect(stub.requests[0].url?.query()?.contains("artistId=3") == true)
    }

    @Test("reads every album, knowing which have songs filed")
    func collection() async throws {
        let stub = StubLidarr(["GET /api/v1/album": json("""
        [{"id":1,"title":"Filed","statistics":{"trackFileCount":3,"trackCount":10}},
         {"id":2,"title":"Wanted","monitored":true,"statistics":{"trackFileCount":0,"trackCount":8}},
         {"id":3,"title":"Unknown"}]
        """)])
        let albums = try await LidarrClient(server: server, apiKey: "k", transport: stub).albums()
        #expect(albums.filter(\.hasFiles).map(\.title) == ["Filed"])
        #expect(stub.requests[0].url?.query() == nil)
    }

    @Test("adding an artist sends what to follow and where to file it")
    func add() async throws {
        let stub = StubLidarr(["POST /api/v1/artist": json(#"{"id":12,"artistName":"Mara Solis","foreignArtistId":"mb-1"}"#, 201)])
        let artist = LidarrArtist(artistName: "Mara Solis", foreignArtistId: "mb-1")
        let added = try await LidarrClient(server: server, apiKey: "k", transport: stub).add(artist, options: options)
        #expect(added.id == 12)
        let body = try JSONSerialization.jsonObject(with: try #require(stub.requests[0].httpBody)) as? [String: Any]
        #expect(body?["foreignArtistId"] as? String == "mb-1")
        #expect(body?["rootFolderPath"] as? String == "/music")
        #expect(body?["qualityProfileId"] as? Int == 1)
        #expect(body?["monitorNewItems"] as? String == "all")
        let addOptions = body?["addOptions"] as? [String: Any]
        #expect(addOptions?["monitor"] as? String == "all")
        #expect(addOptions?["searchForMissingAlbums"] as? Bool == true)
    }

    @Test("says why Lidarr refused, and when the key is wrong")
    func errors() async {
        let refused = StubLidarr(["POST /api/v1/artist": json(#"[{"propertyName":"ForeignArtistId","errorMessage":"This artist has already been added"}]"#, 400)])
        await #expect(throws: LidarrError.rejected("This artist has already been added")) {
            _ = try await LidarrClient(server: server, apiKey: "k", transport: refused)
                .add(LidarrArtist(artistName: "A", foreignArtistId: "a"), options: options)
        }
        let locked = StubLidarr(["GET /api/v1/system/status": json("Unauthorized", 401)])
        await #expect(throws: LidarrError.wrongKey) {
            _ = try await LidarrClient(server: server, apiKey: "k", transport: locked).status()
        }
        let web = StubLidarr(["GET /api/v1/system/status": json("<html>Hello</html>")])
        await #expect(throws: LidarrError.notLidarr) {
            _ = try await LidarrClient(server: server, apiKey: "k", transport: web).status()
        }
    }

    @Test("an artist already followed isn't added again")
    func followExisting() async throws {
        let stub = StubLidarr(["GET /api/v1/artist": json(#"[{"id":3,"artistName":"MARA SOLIS","foreignArtistId":"mb-1"}]"#)])
        let (artist, isNew) = try await LidarrClient(server: server, apiKey: "k", transport: stub).follow(artistNamed: "Mara Solis", options: options)
        #expect(artist.id == 3)
        #expect(!isNew)
        #expect(!stub.requests.contains { $0.httpMethod == "POST" })
    }

    @Test("asking for an album follows its artist quietly, then follows and searches the album")
    func requestAlbum() async throws {
        let stub = StubLidarr([
            "GET /api/v1/artist": json("[]"),
            "GET /api/v1/artist/lookup": json(#"[{"artistName":"Nova Harbor","foreignArtistId":"mb-2"}]"#),
            "POST /api/v1/artist": json(#"{"id":5,"artistName":"Nova Harbor","foreignArtistId":"mb-2"}"#, 201),
            "GET /api/v1/album": json(#"[{"id":40,"title":"Tides"},{"id":41,"title":"Coastlines"}]"#),
            "PUT /api/v1/album/monitor": json("", 202),
            "POST /api/v1/command": json(#"{"id":99}"#, 201),
        ])
        let album = try await LidarrClient(server: server, apiKey: "k", transport: stub)
            .request(album: "Coastlines (Deluxe Edition)", by: "Nova Harbor", options: options, waitStep: .milliseconds(1))
        #expect(album.id == 41)
        let add = try #require(stub.requests.first { $0.httpMethod == "POST" && $0.url?.path() == "/api/v1/artist" })
        let body = try JSONSerialization.jsonObject(with: try #require(add.httpBody)) as? [String: Any]
        // Only the album asked for: not everything the artist has.
        #expect((body?["addOptions"] as? [String: Any])?["monitor"] as? String == "none")
        #expect(body?["monitorNewItems"] as? String == "none")
        let command = try #require(stub.requests.last { $0.url?.path() == "/api/v1/command" })
        let search = try JSONSerialization.jsonObject(with: try #require(command.httpBody)) as? [String: Any]
        #expect(search?["name"] as? String == "AlbumSearch")
        #expect(search?["albumIds"] as? [Int] == [41])
    }

    @Test("reads the queue, with how far each download has got")
    func queue() async throws {
        let stub = StubLidarr(["GET /api/v1/queue": json("""
        {"page":1,"pageSize":100,"totalRecords":1,"records":[{"id":1,"title":"Coastlines","status":"downloading",
          "trackedDownloadState":"downloading","size":1000,"sizeleft":250,"timeleft":"00:02:10",
          "album":{"id":41,"title":"Coastlines"},"artist":{"id":5,"artistName":"Nova Harbor","foreignArtistId":"mb-2"}}]}
        """)])
        let items = try await LidarrClient(server: server, apiKey: "k", transport: stub).queue()
        #expect(items.count == 1)
        #expect(items[0].progress == 0.75)
        #expect(items[0].album?.title == "Coastlines")
    }

    @Test("album titles match without the edition, and only the edition")
    func albumKey() {
        #expect(LidarrClient.albumKey("Coastlines (Deluxe Edition)") == "coastlines")
        #expect(LidarrClient.albumKey("Coastlines - Single") == "coastlines")
        #expect(LidarrClient.albumKey("Tides [Remastered]") == "tides")
        #expect(LidarrClient.albumKey("1989 (Taylor's Version)") == "1989 (taylor's version)")
    }

    @Test("an album is matched exactly first, and never by half a word")
    func albumMatching() {
        func album(_ id: Int, _ title: String) -> LidarrAlbum {
            try! JSONDecoder().decode(LidarrAlbum.self, from: Data(#"{"id":\#(id),"title":"\#(title)"}"#.utf8))
        }
        let albums = [album(1, "America"), album(2, "Nevermind"), album(3, "Nevermind (Remastered)"), album(4, "folklore"), album(5, "1989")]
        #expect(LidarrClient.match("Americana", in: albums) == nil)
        #expect(LidarrClient.match("Nevermind (Remastered)", in: albums)?.id == 3)
        #expect(LidarrClient.match("Nevermind (Deluxe Edition)", in: albums)?.id == 2)
        #expect(LidarrClient.match("1989 (Taylor's Version)", in: albums) == nil)
        #expect(LidarrClient.match("folklore: the long pond studio sessions", in: albums) == nil)
        #expect(LidarrClient.match("Folklore", in: albums)?.id == 4)
    }

    @Test("a shared credit is looked for whole, then as its first artist, never as someone else")
    func collaborations() async throws {
        #expect(LidarrClient.artistCandidates("Drake & 21 Savage") == ["Drake & 21 Savage", "Drake"])
        let stub = StubLidarr([
            "GET /api/v1/artist": json("[]"),
            "GET /api/v1/artist/lookup": { request in
                request.url?.query()?.contains("21") == true
                    ? (#"[{"artistName":"Someone Else","foreignArtistId":"x"}]"#, 200)
                    : (#"[{"artistName":"Drake","foreignArtistId":"mb-d"}]"#, 200)
            },
            "POST /api/v1/artist": json(#"{"id":9,"artistName":"Drake","foreignArtistId":"mb-d"}"#, 201),
        ])
        let (artist, isNew) = try await LidarrClient(server: server, apiKey: "k", transport: stub).follow(artistNamed: "Drake & 21 Savage", options: options)
        #expect(artist.artistName == "Drake")
        #expect(isNew)
        let nobody = StubLidarr(["GET /api/v1/artist": json("[]"), "GET /api/v1/artist/lookup": json(#"[{"artistName":"Nobody Near","foreignArtistId":"n"}]"#)])
        await #expect(throws: LidarrError.self) {
            _ = try await LidarrClient(server: server, apiKey: "k", transport: nobody).follow(artistNamed: "Mara Solis", options: options)
        }
        #expect(!nobody.requests.contains { $0.httpMethod == "POST" })
    }
}

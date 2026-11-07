import Testing
import Foundation
@testable import TracksCore

@Suite("Searching for songs in the App Clip")
struct SharePlaySongSearchTests {
    private func response(_ results: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["resultCount": results.count, "results": results])
    }

    private func track(_ id: Int, _ title: String, _ explicitness: String = "notExplicit", kind: String = "song", streamable: Bool = true) -> [String: Any] {
        [
            "kind": kind, "trackId": id, "trackName": title, "artistName": "Sabrina Carpenter",
            "collectionName": "Short n' Sweet", "trackExplicitness": explicitness, "isStreamable": streamable,
            "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg",
        ]
    }

    @Test("a song arrives with its catalog id, names and a larger cover")
    func readsASong() throws {
        let songs = SharePlaySongSearch.songs(from: try response([track(1, "Juno")]), allowsExplicit: true)
        #expect(songs == [SharePlaySong(
            catalogID: "1", title: "Juno", artistName: "Sabrina Carpenter", albumTitle: "Short n' Sweet",
            artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/a/300x300bb.jpg"
        )])
    }

    @Test("explicit songs on at the host: the original, not its clean twin")
    func prefersOriginal() throws {
        let songs = SharePlaySongSearch.songs(from: try response([track(2, "Espresso", "cleaned"), track(1, "Espresso", "explicit")]), allowsExplicit: true)
        #expect(songs.map(\.catalogID) == ["1"])
        #expect(songs.first?.isExplicit == true)
    }

    @Test("explicit songs off at the host: the clean version, where there is one")
    func prefersClean() throws {
        let songs = SharePlaySongSearch.songs(from: try response([track(1, "Espresso", "explicit"), track(2, "Espresso", "cleaned"), track(3, "Taste", "explicit")]), allowsExplicit: false)
        #expect(songs.map(\.catalogID) == ["2", "3"])
    }

    @Test("videos and songs that can't stream are left out")
    func leavesOutWhatCantPlay() throws {
        let songs = SharePlaySongSearch.songs(from: try response([track(1, "Juno", kind: "music-video"), track(2, "Taste", streamable: false), track(3, "Bed Chem")]), allowsExplicit: true)
        #expect(songs.map(\.catalogID) == ["3"])
    }

    @Test("a response that isn't one gives no songs")
    func junk() {
        #expect(SharePlaySongSearch.songs(from: Data("<html>".utf8), allowsExplicit: true).isEmpty)
    }

    @Test("the request searches songs in the storefront")
    func request() throws {
        let url = try #require(SharePlaySongSearch.url(for: "good luck, babe", storefront: "GB"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.host() == "itunes.apple.com")
        #expect(items.contains(URLQueryItem(name: "term", value: "good luck, babe")))
        #expect(items.contains(URLQueryItem(name: "entity", value: "song")))
        #expect(items.contains(URLQueryItem(name: "country", value: "gb")))
    }

    @Test("the storefront follows the region, or the US store without one", arguments: [("GB", "gb"), (nil, "us"), ("419", "us")] as [(String?, String)])
    func storefront(region: String?, expected: String) {
        #expect(SharePlaySongSearch.storefront(region: region) == expected)
    }
}

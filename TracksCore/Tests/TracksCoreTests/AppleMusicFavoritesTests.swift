import Testing
import Foundation
@testable import TracksCore

@Suite("Apple Music favorites")
struct AppleMusicFavoritesTests {

    @Test("favorite PUTs a love rating on the catalog song")
    func favorite() throws {
        let request = try AppleMusicFavorites.favorite(songID: "1440857781")

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://api.music.apple.com/v1/me/ratings/songs/1440857781")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let attributes = try #require(json["attributes"] as? [String: Any])
        #expect(json["type"] as? String == "rating")
        #expect(attributes["value"] as? Int == 1)
    }

    @Test("library songs are rated under library-songs")
    func librarySong() throws {
        let request = try AppleMusicFavorites.favorite(songID: "i.abc123")
        #expect(request.url?.absoluteString == "https://api.music.apple.com/v1/me/ratings/library-songs/i.abc123")
    }

    @Test("unfavorite DELETEs the rating")
    func unfavorite() {
        let request = AppleMusicFavorites.unfavorite(songID: "1440857781")
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString == "https://api.music.apple.com/v1/me/ratings/songs/1440857781")
        #expect(request.httpBody == nil)
    }

    @Test("ratings asks for all the songs at once")
    func ratings() {
        let request = AppleMusicFavorites.ratings(songIDs: ["1", "2", "3"])
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.music.apple.com/v1/me/ratings/songs?ids=1,2,3")
    }

    @Test("only loved songs are favorites")
    func favoriteIDs() {
        let reply = Data("""
        {"data": [
            {"id": "1", "type": "ratings", "attributes": {"value": 1}},
            {"id": "2", "type": "ratings", "attributes": {"value": -1}},
            {"id": "3", "type": "ratings"}
        ]}
        """.utf8)
        #expect(AppleMusicFavorites.favoriteIDs(in: reply) == ["1"])
        #expect(AppleMusicFavorites.favoriteIDs(in: Data("{}".utf8)).isEmpty)
        #expect(AppleMusicFavorites.favoriteIDs(in: Data()).isEmpty)
    }
}

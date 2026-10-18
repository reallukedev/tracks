import Foundation

/// Builds the Apple Music REST requests that favorite a song, as the star in Music does.
///
/// MusicKit has no favorite call, but Apple Music's ratings are what the star sets: a "love"
/// rating (value 1) shows in Music as a favorite. This only builds the requests and reads
/// the replies, so it can be tested without MusicKit or a network.
///
/// No `Authorization` header: `MusicDataRequest` adds the tokens itself.
public enum AppleMusicFavorites {
    public static let baseURL = URL(string: "https://api.music.apple.com/v1/me/ratings")!

    /// `PUT /v1/me/ratings/songs/{id}` with a love rating. Responds 200 with the rating.
    public static func favorite(songID: String) throws -> URLRequest {
        let body: [String: Any] = ["type": "rating", "attributes": ["value": 1]]
        var request = URLRequest(url: url(songID: songID))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `DELETE /v1/me/ratings/songs/{id}`. Responds 204 with an empty body.
    public static func unfavorite(songID: String) -> URLRequest {
        var request = URLRequest(url: url(songID: songID))
        request.httpMethod = "DELETE"
        return request
    }

    /// `GET /v1/me/ratings/songs?ids=…`, for which of these catalog songs are favorites.
    /// Songs without a rating are simply left out of the reply.
    public static func ratings(songIDs: [String]) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "songs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ids", value: songIDs.joined(separator: ","))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    /// The songs a ratings reply says are loved. A dislike (-1) isn't a favorite.
    public static func favoriteIDs(in data: Data) -> Set<String> {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]]
        else { return [] }
        return Set(items.compactMap { item in
            guard
                let id = item["id"] as? String,
                let attributes = item["attributes"] as? [String: Any],
                (attributes["value"] as? Int) == 1
            else { return nil }
            return id
        })
    }

    /// Library songs ("i." ids) are rated under their own path; catalog songs under songs.
    static func url(songID: String) -> URL {
        let kind = isLibraryID(songID) ? "library-songs" : "songs"
        return baseURL.appending(path: kind).appending(path: songID)
    }

    static func isLibraryID(_ id: String) -> Bool {
        id.hasPrefix("i.")
    }
}

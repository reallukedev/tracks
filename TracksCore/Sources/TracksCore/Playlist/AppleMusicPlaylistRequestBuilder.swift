import Foundation

/// Builds the Apple Music REST requests that create and populate the playlist.
///
/// `MusicLibrary`'s write methods are `@available(macOS, unavailable)` in the macOS 27 SDK,
/// so REST is the only path on both platforms. This only builds the requests, so it can be
/// tested without MusicKit or a network.
///
/// No `Authorization` header: `MusicDataRequest` adds the tokens itself, and the URLSession
/// fallback uses ``authorized(_:developerToken:userToken:)``.
public enum AppleMusicPlaylistRequestBuilder {
    public static let baseURL = URL(string: "https://api.music.apple.com/v1/me/library")!

    /// `POST /v1/me/library/playlists`
    public static func createPlaylist(
        name: String,
        description: String? = nil
    ) throws -> URLRequest {
        var attributes: [String: String] = ["name": name]
        if let description { attributes["description"] = description }
        let body: [String: Any] = ["attributes": attributes]

        var request = URLRequest(url: baseURL.appending(path: "playlists"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `POST /v1/me/library/playlists/{id}/tracks`
    ///
    /// Responds 204 with an empty body on success, so there's nothing to decode.
    public static func addTracks(
        songIDs: [String],
        toPlaylist playlistID: String
    ) throws -> URLRequest {
        let data = songIDs.map { ["id": $0, "type": "songs"] }
        let body: [String: Any] = ["data": data]

        var request = URLRequest(
            url: baseURL.appending(path: "playlists").appending(path: playlistID).appending(path: "tracks")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // No delete or remove-track request: DELETE on /v1/me/library/playlists/{id} returns
    // 401 even with valid tokens, and there's no endpoint for removing a track. Once a song
    // is in "Heard on Radio", the app can't take it out, which is why Tracks offers no cap on
    // the playlist's size: a cap could only fill up and then stop adding.

    /// `GET /v1/me/library/playlists/{id}`
    public static func playlist(id playlistID: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "playlists").appending(path: playlistID))
        request.httpMethod = "GET"
        return request
    }

    /// `GET /v1/me/library/playlists`
    public static func listPlaylists(limit: Int = 100) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: "playlists"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    /// Adds the token headers `MusicDataRequest` would otherwise supply, for the URLSession
    /// fallback.
    public static func authorized(
        _ request: URLRequest,
        developerToken: String,
        userToken: String
    ) -> URLRequest {
        var request = request
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userToken, forHTTPHeaderField: "Music-User-Token")
        return request
    }

    /// Whether a status code means the write succeeded. The add endpoint returns 204;
    /// create returns 201.
    public static func isSuccess(statusCode: Int) -> Bool {
        (200..<300).contains(statusCode)
    }
}

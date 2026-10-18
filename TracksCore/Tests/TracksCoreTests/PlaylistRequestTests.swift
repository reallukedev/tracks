import Testing
import Foundation
@testable import TracksCore

/// Request building lives in the MusicKit-free core so these run without a network,
/// subscription or device.
@Suite("Apple Music playlist requests")
struct PlaylistRequestTests {

    @Test("create targets the library playlists endpoint with a POST")
    func createEndpoint() throws {
        let request = try AppleMusicPlaylistRequestBuilder.createPlaylist(name: "Heard on Radio")

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.music.apple.com/v1/me/library/playlists")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test("create body nests the name under attributes")
    func createBody() throws {
        let request = try AppleMusicPlaylistRequestBuilder.createPlaylist(
            name: "Heard on Radio",
            description: "Captured from Apple Music Radio"
        )
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let attributes = try #require(json["attributes"] as? [String: String])

        #expect(attributes["name"] == "Heard on Radio")
        #expect(attributes["description"] == "Captured from Apple Music Radio")
    }

    @Test("create omits description when none is given")
    func createWithoutDescription() throws {
        let request = try AppleMusicPlaylistRequestBuilder.createPlaylist(name: "Heard on Radio")
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let attributes = try #require(json["attributes"] as? [String: String])

        #expect(attributes["description"] == nil)
    }

    @Test("add tracks targets the playlist's tracks collection")
    func addTracksEndpoint() throws {
        let request = try AppleMusicPlaylistRequestBuilder.addTracks(
            songIDs: ["1440857781"],
            toPlaylist: "p.abc123"
        )

        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString
                == "https://api.music.apple.com/v1/me/library/playlists/p.abc123/tracks"
        )
    }

    @Test("add tracks sends each song as a typed resource identifier")
    func addTracksBody() throws {
        let request = try AppleMusicPlaylistRequestBuilder.addTracks(
            songIDs: ["1440857781", "1440857782"],
            toPlaylist: "p.abc123"
        )
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try #require(json["data"] as? [[String: String]])

        #expect(data.count == 2)
        #expect(data[0]["id"] == "1440857781")
        #expect(data[0]["type"] == "songs")
        #expect(data[1]["id"] == "1440857782")
    }

    @Test("the fallback transport adds both token headers")
    func authorizationHeaders() throws {
        let base = try AppleMusicPlaylistRequestBuilder.createPlaylist(name: "x")
        let authorized = AppleMusicPlaylistRequestBuilder.authorized(
            base,
            developerToken: "dev-token",
            userToken: "user-token"
        )

        #expect(authorized.value(forHTTPHeaderField: "Authorization") == "Bearer dev-token")
        #expect(authorized.value(forHTTPHeaderField: "Music-User-Token") == "user-token")
    }

    /// Adding tracks succeeds with 204 and no body.
    @Test("success covers the whole 2xx range including 204 No Content",
          arguments: [200, 201, 202, 204])
    func successStatuses(code: Int) {
        #expect(AppleMusicPlaylistRequestBuilder.isSuccess(statusCode: code))
    }

    @Test("failure statuses are not treated as success", arguments: [400, 401, 403, 404, 429, 500])
    func failureStatuses(code: Int) {
        #expect(!AppleMusicPlaylistRequestBuilder.isSuccess(statusCode: code))
    }

    @Test("auth and rate-limit failures are retryable, malformed requests are not")
    func errorClassification() {
        #expect(PlaylistWriteError.classify(statusCode: 401, message: "").isRetryable)
        #expect(PlaylistWriteError.classify(statusCode: 429, message: "").isRetryable)
        #expect(PlaylistWriteError.classify(statusCode: 503, message: "").isRetryable)
        #expect(!PlaylistWriteError.classify(statusCode: 400, message: "").isRetryable)
        #expect(!PlaylistWriteError.classify(statusCode: 404, message: "").isRetryable)
    }
}

/// A missing developer token is a setup problem. Retrying it would stall the write queue
/// for good.
@Suite("Configuration failures")
struct ConfigurationErrorTests {

    @Test("a token failure is never retryable")
    func notRetryable() {
        let error = PlaylistWriteError.notConfigured(
            reason: "developerTokenRequestFailed",
            guidance: "Enable MusicKit for this App ID."
        )
        #expect(!error.isRetryable)
    }

    @Test("a token failure carries actionable guidance")
    func carriesGuidance() throws {
        let error = PlaylistWriteError.notConfigured(
            reason: "developerTokenRequestFailed",
            guidance: "Enable MusicKit for this App ID."
        )
        let guidance = try #require(error.guidance)
        #expect(guidance.contains("MusicKit"))
    }

    /// There's nothing a user can do about a 503.
    @Test("transport failures carry no guidance")
    func transportHasNoGuidance() {
        #expect(PlaylistWriteError.classify(statusCode: 503, message: "").guidance == nil)
    }
}

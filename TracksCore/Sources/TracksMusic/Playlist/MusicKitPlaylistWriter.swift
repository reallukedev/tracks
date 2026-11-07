import Foundation
import MusicKit
import TracksCore

/// Writes playlists on both iOS and macOS through the Apple Music API.
///
/// `MusicLibrary.createPlaylist` and `MusicLibrary.add(_:to:)` are unavailable in the macOS 27
/// SDK. `MusicDataRequest` works on both and attaches the developer and user tokens itself.
/// If it fails, the same request is retried through `URLSession` with tokens from
/// `DefaultMusicTokenProvider`. The probe reports which path worked.
public struct MusicKitPlaylistWriter: PlaylistWriter {
    public enum Transport: String, Sendable {
        case musicDataRequest
        case urlSessionFallback
    }

    /// Set when a request succeeds, so the probe can report which transport carried it.
    public let onTransportUsed: @Sendable (Transport) -> Void

    public init(onTransportUsed: @escaping @Sendable (Transport) -> Void = { _ in }) {
        self.onTransportUsed = onTransportUsed
    }

    public func createPlaylist(name: String, description: String?) async throws -> String {
        let request = try AppleMusicPlaylistRequestBuilder.createPlaylist(
            name: name,
            description: description
        )
        let (data, _) = try await perform(request)
        return try Self.parseCreatedPlaylistID(from: data)
    }

    public func addSongs(ids: [String], toPlaylist playlistID: String) async throws {
        guard !ids.isEmpty else { return }
        let request = try AppleMusicPlaylistRequestBuilder.addTracks(
            songIDs: ids,
            toPlaylist: playlistID
        )
        // 204 with an empty body.
        _ = try await perform(request)
    }

    public func playlistExists(_ playlistID: String) async throws -> Bool {
        do {
            _ = try await perform(AppleMusicPlaylistRequestBuilder.playlist(id: playlistID))
            return true
        } catch PlaylistWriteError.permanent(let status, _) where status == 404 {
            return false
        }
    }

    public func existingPlaylist(named name: String) async throws -> String? {
        try await listPlaylists().first { $0.name == name }?.id
    }

    /// Library playlists, as (id, name) pairs.
    public func listPlaylists() async throws -> [(id: String, name: String)] {
        let (data, _) = try await perform(AppleMusicPlaylistRequestBuilder.listPlaylists())
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]]
        else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let attributes = item["attributes"] as? [String: Any]
            return (id: id, name: attributes?["name"] as? String ?? "")
        }
    }

    // MARK: - Transport

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let response = try await MusicDataRequest(urlRequest: request).response()
            let status = response.urlResponse.statusCode
            guard AppleMusicPlaylistRequestBuilder.isSuccess(statusCode: status) else {
                let body = String(data: response.data, encoding: .utf8) ?? ""
                // A missing Music User Token gets a bare 401 with an empty body, so work out
                // the actual cause.
                if status == 401 {
                    throw await Self.diagnoseUnauthorized()
                }
                throw PlaylistWriteError.classify(
                    statusCode: status,
                    message: body.isEmpty ? "empty body" : body
                )
            }
            onTransportUsed(.musicDataRequest)
            return (response.data, status)
        } catch let error as PlaylistWriteError {
            // An HTTP failure, so another client wouldn't help.
            throw error
        } catch let error as MusicTokenRequestError {
            // The fallback needs the same tokens and would fail the same way.
            throw Self.configurationError(for: error)
        } catch let error as URLError where request.httpMethod == "POST" {
            // A timeout or a dropped connection can come after Apple has done the work, and
            // sending it again would add the song twice or make a second playlist.
            throw PlaylistWriteError.transient(statusCode: nil, message: "MusicDataRequest failed: \(error)")
        } catch {
            return try await performViaURLSession(request, primaryError: error)
        }
    }

    private func performViaURLSession(
        _ request: URLRequest,
        primaryError: any Error
    ) async throws -> (Data, Int) {
        let provider = DefaultMusicTokenProvider()
        let developerToken: String
        let userToken: String
        do {
            developerToken = try await provider.developerToken(options: .ignoreCache)
            userToken = try await provider.userToken(for: developerToken, options: .ignoreCache)
        } catch let error as MusicTokenRequestError {
            throw Self.configurationError(for: error)
        } catch {
            throw PlaylistWriteError.transient(
                statusCode: nil,
                message: "MusicDataRequest failed (\(primaryError)) and token fetch also failed (\(error))"
            )
        }

        let authorized = AppleMusicPlaylistRequestBuilder.authorized(
            request,
            developerToken: developerToken,
            userToken: userToken
        )
        let (data, response) = try await URLSession.shared.data(for: authorized)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard AppleMusicPlaylistRequestBuilder.isSuccess(statusCode: status) else {
            throw PlaylistWriteError.classify(
                statusCode: status,
                message: String(data: data, encoding: .utf8) ?? "no body"
            )
        }
        onTransportUsed(.urlSessionFallback)
        return (data, status)
    }

    /// Works out why the library endpoint returned 401.
    ///
    /// `/v1/me/library/…` needs a Music User Token, which MusicKit only attaches once the app
    /// is authorised. So it's usually authorisation, but it can also be a revoked token or no
    /// subscription.
    static func diagnoseUnauthorized() async -> PlaylistWriteError {
        let status = MusicAuthorization.currentStatus
        guard status == .authorized else {
            return .notConfigured(
                reason: "HTTP 401 and MusicKit authorization is \(status)",
                guidance: """
                Tracks has not been allowed to access Apple Music, so no Music User Token \
                is attached to library requests. Answer the "Allow Tracks to access your \
                music" prompt, or enable it in System Settings › Privacy & Security › \
                Media & Apple Music.
                """
            )
        }

        do {
            let provider = DefaultMusicTokenProvider()
            let developerToken = try await provider.developerToken(options: .ignoreCache)
            _ = try await provider.userToken(for: developerToken, options: .ignoreCache)
        } catch let error as MusicTokenRequestError {
            return configurationError(for: error)
        } catch {
            return .transient(statusCode: 401, message: "Token refresh failed: \(error)")
        }

        do {
            let subscription = try await MusicSubscription.current
            if !subscription.canPlayCatalogContent { return .notSubscribed }
        } catch {
            // Don't let a failed subscription check hide the 401.
        }

        // Authorised, tokens issue and the subscription is fine, so retry later.
        return .transient(statusCode: 401, message: "Authorized with valid tokens; treating as transient.")
    }

    /// Turns a token failure into something the user can act on.
    ///
    /// Only the failures that name a cause become ``PlaylistWriteError/notConfigured``. A user
    /// token request that simply failed, or one MusicKit can't explain, is what a dropped
    /// connection produces too, so those are transient rather than sending the user off to
    /// sign in again.
    static func configurationError(for error: MusicTokenRequestError) -> PlaylistWriteError {
        switch error {
        case .developerTokenRequestFailed, .userNotSignedIn, .userTokenRevoked,
             .privacyAcknowledgementRequired, .permissionDenied:
            break
        default:
            return .transient(statusCode: nil, message: "MusicKit token request failed: \(error)")
        }
        let guidance: String = switch error {
        case .developerTokenRequestFailed:
            """
            MusicKit could not issue a developer token. Check that the App ID for this \
            bundle is an Explicit App ID with MusicKit enabled under App Services, that \
            DEVELOPMENT_TEAM is set in Config/Tracks.xcconfig, and that the build is \
            signed with that team. An ad-hoc signed build has no provisioning profile and \
            will always fail here.
            """
        case .userNotSignedIn:
            "Sign in to Apple Music in Settings, then try again."
        case .userTokenRevoked:
            "Access was revoked. Re-authorise Tracks in Settings › Privacy › Media & Apple Music."
        case .privacyAcknowledgementRequired:
            "Open Apple Music once and accept its privacy terms, then try again."
        case .permissionDenied:
            "Tracks was denied access to Apple Music. Grant it in Settings › Privacy › Media & Apple Music."
        default:
            "MusicKit could not issue a token."
        }
        return .notConfigured(reason: String(describing: error), guidance: guidance)
    }

    /// Pulls the new playlist's library ID out of the create response.
    static func parseCreatedPlaylistID(from data: Data) throws -> String {
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let items = root["data"] as? [[String: Any]],
            let id = items.first?["id"] as? String
        else {
            throw PlaylistWriteError.permanent(
                statusCode: nil,
                message: "Could not find a playlist id in the create response"
            )
        }
        return id
    }
}

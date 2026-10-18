import Foundation

/// Builds the Apple Music REST request that adds catalog items to the library, as Add to
/// Library does in Music.
///
/// `MusicLibrary.add(_:)` exists only on iOS, so the Mac adds through the same endpoint Music
/// uses. This only builds the request, so it can be tested without MusicKit or a network.
///
/// No `Authorization` header: `MusicDataRequest` adds the tokens itself.
public enum AppleMusicLibraryAdd {
    public static let url = URL(string: "https://api.music.apple.com/v1/me/library")!

    /// The catalog types the endpoint takes, as its query names them.
    public enum Kind: String, Sendable {
        case songs, albums, playlists
    }

    /// `POST /v1/me/library?ids[songs]=…`. Responds 202 once the library has the request.
    /// Library ids ("i." and "l." prefixes) are already in the library and are left out, so a
    /// request with nothing else in it comes back nil.
    public static func request(adding ids: [String], as kind: Kind) -> URLRequest? {
        let catalogIDs = ids.filter { !$0.isEmpty && !$0.hasPrefix("i.") && !$0.hasPrefix("l.") && !$0.hasPrefix("p.") }
        guard !catalogIDs.isEmpty else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "ids[\(kind.rawValue)]", value: catalogIDs.joined(separator: ","))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        return request
    }
}

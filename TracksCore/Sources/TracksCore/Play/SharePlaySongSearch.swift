import Foundation

/// Searching Apple Music's catalog without MusicKit, for the App Clip: Apple's public search,
/// which needs no sign-in or permission, so a passenger can pick songs the moment the App Clip
/// opens. Its track ids are Apple Music's catalog ids, which the host looks up and plays as
/// it would any other.
public enum SharePlaySongSearch {
    /// The request for a search in a storefront, like `us`.
    public static func url(for term: String, storefront: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/search"
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "country", value: storefront.lowercased()),
        ]
        return components.url
    }

    /// The songs in a response, one version of each: the clean one where explicit songs are
    /// off at the host, and the original where they're on.
    public static func songs(from data: Data, allowsExplicit: Bool) -> [SharePlaySong] {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        let songs = response.results.compactMap { result -> (song: SharePlaySong, isCleaned: Bool)? in
            guard result.kind == "song", result.isStreamable != false,
                  let id = result.trackId, let title = result.trackName, let artist = result.artistName
            else { return nil }
            let song = SharePlaySong(
                catalogID: String(id),
                title: title,
                artistName: artist,
                albumTitle: result.collectionName,
                artworkURL: result.artworkUrl100.map { $0.replacingOccurrences(of: "100x100bb", with: "300x300bb") },
                isExplicit: result.trackExplicitness == "explicit"
            )
            return (song, result.trackExplicitness == "cleaned")
        }
        let identities = Dictionary(grouping: songs, by: \.song.identity)
        var seen = Set<String>()
        return songs.compactMap { entry in
            let identity = entry.song.identity
            let versions = identities[identity] ?? []
            let preferred = versions.first { allowsExplicit ? $0.song.isExplicit : $0.isCleaned || !$0.song.isExplicit } ?? versions.first
            guard preferred?.song == entry.song, seen.insert(identity).inserted else { return nil }
            return entry.song
        }
    }

    /// The storefront for a region, like `US`, or the US store when there's none.
    public static func storefront(region: String?) -> String {
        guard let region, region.count == 2 else { return "us" }
        return region.lowercased()
    }

    private struct Response: Decodable {
        var results: [Result]
    }

    private struct Result: Decodable {
        var kind: String?
        var trackId: Int?
        var trackName: String?
        var artistName: String?
        var collectionName: String?
        var artworkUrl100: String?
        var trackExplicitness: String?
        var isStreamable: Bool?
    }
}

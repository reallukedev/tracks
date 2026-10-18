import Foundation

/// What Last.fm knows about a song: how widely it's heard, how its listeners tag it, its wiki
/// summary, and the songs its listeners also play.
public struct LastFMTrackInfo: Codable, Sendable, Equatable {
    public struct SimilarTrack: Codable, Sendable, Hashable, Identifiable {
        public let title: String
        public let artistName: String

        public var id: String { "\(artistName)\u{1F}\(title)" }

        public init(title: String, artistName: String) {
            self.title = title
            self.artistName = artistName
        }
    }

    public var listeners: Int?
    public var scrobbles: Int?
    /// The connected account's own scrobbles of it.
    public var yourScrobbles: Int?
    public var tags: [String]
    /// Plain text, without Last.fm's trailing "Read more" link.
    public var summary: String?
    public var url: URL?
    public var similar: [SimilarTrack]

    public init(
        listeners: Int? = nil,
        scrobbles: Int? = nil,
        yourScrobbles: Int? = nil,
        tags: [String] = [],
        summary: String? = nil,
        url: URL? = nil,
        similar: [SimilarTrack] = []
    ) {
        self.listeners = listeners
        self.scrobbles = scrobbles
        self.yourScrobbles = yourScrobbles
        self.tags = tags
        self.summary = summary
        self.url = url
        self.similar = similar
    }

    /// Nothing worth a section.
    public var isEmpty: Bool {
        (listeners ?? 0) == 0 && (scrobbles ?? 0) == 0 && tags.isEmpty && summary == nil && similar.isEmpty
    }
}

extension LastFMClient {
    /// Tags shown at most; Last.fm's list runs on into noise.
    static let tagLimit = 5

    /// The song's numbers, tags and wiki. `username` adds that account's own count. Nil when
    /// Last.fm doesn't know the song.
    public func trackInfo(title: String, artistName: String, username: String?) async throws -> LastFMTrackInfo? {
        var parameters = ["method": "track.getInfo", "track": title, "artist": artistName, "autocorrect": "1"]
        if let username { parameters["username"] = username }
        do {
            return Self.trackInfo(from: try await call(parameters), artistName: artistName, title: title)
        } catch LastFMError.service(let code, _) where code == 6 {
            return nil
        }
    }

    /// Songs Last.fm's listeners play alongside this one, most alike first.
    public func similarTracks(title: String, artistName: String, limit: Int = 6) async throws -> [LastFMTrackInfo.SimilarTrack] {
        let parameters = ["method": "track.getSimilar", "track": title, "artist": artistName, "autocorrect": "1", "limit": String(limit)]
        do {
            return Self.similarTracks(from: try await call(parameters))
        } catch LastFMError.service(let code, _) where code == 6 {
            return []
        }
    }

    static func trackInfo(from json: [String: Any], artistName: String, title: String) -> LastFMTrackInfo? {
        guard let track = json["track"] as? [String: Any] else { return nil }
        let tagEntries = (track["toptags"] as? [String: Any])?["tag"]
        let tags: [[String: Any]] = switch tagEntries {
        case let many as [[String: Any]]: many
        case let one as [String: Any]: [one]
        default: []
        }
        let wiki = (track["wiki"] as? [String: Any])?["summary"] as? String
        return LastFMTrackInfo(
            listeners: integer(track["listeners"]),
            scrobbles: integer(track["playcount"]),
            yourScrobbles: integer(track["userplaycount"]),
            tags: usefulTags(tags.compactMap { $0["name"] as? String }, artistName: artistName, title: title),
            summary: wiki.flatMap(plainSummary),
            url: (track["url"] as? String).flatMap(URL.init(string:))
        )
    }

    static func similarTracks(from json: [String: Any]) -> [LastFMTrackInfo.SimilarTrack] {
        let entries: [[String: Any]] = switch (json["similartracks"] as? [String: Any])?["track"] {
        case let many as [[String: Any]]: many
        case let one as [String: Any]: [one]
        default: []
        }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let title = entry["name"] as? String, !title.isEmpty,
                  let artist = (entry["artist"] as? [String: Any])?["name"] as? String, !artist.isEmpty
            else { return nil }
            let track = LastFMTrackInfo.SimilarTrack(title: title, artistName: artist)
            return seen.insert(track.id.lowercased()).inserted ? track : nil
        }
    }

    /// The tags that say something: not the artist's or the song's own name, each once however
    /// it's spelt ("Hip-Hop", "hip hop"), with a capital where it was all lowercase.
    static func usefulTags(_ tags: [String], artistName: String, title: String) -> [String] {
        let key: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        var seen: Set<String> = [key(artistName), key(title)]
        var useful: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(key(trimmed)).inserted else { continue }
            useful.append(trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed)
            if useful.count == tagLimit { break }
        }
        return useful
    }

    /// Last.fm's summary as plain text: its tags, its entities and its "Read more on Last.fm"
    /// link gone. Nil when nothing's left.
    static func plainSummary(_ html: String) -> String? {
        var text = html
        if let link = text.range(of: "<a href=", options: .backwards) {
            text = String(text[..<link.lowerBound])
        }
        text = text.replacing(/<[^>]+>/, with: "")
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: number
        case let text as String: Int(text)
        default: nil
        }
    }
}

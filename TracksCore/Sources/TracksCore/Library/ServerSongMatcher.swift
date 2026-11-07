import Foundation

/// Finds a song among a music server's search results when the two name it differently, as
/// Apple Music and a server like Octo, which names songs as Last.fm does, often do:
/// "Havana (feat. Young Thug)" is "Havana", "Yeat & Drake" is "Yeat", and "Song - Remastered
/// 2011" is "Song". A live, remixed or other different recording still doesn't match.
public enum ServerSongMatcher {
    /// The first result that's the same song: named exactly the same if one is, else the
    /// first whose title matches and that shares an artist.
    public static func bestMatch(title: String, artist: String, in candidates: [SubsonicSong]) -> SubsonicSong? {
        let identity = HistoryImport.key(title: title, artistName: artist)
        if let exact = candidates.first(where: { HistoryImport.key(title: $0.title, artistName: $0.artist ?? "") == identity }) {
            return exact
        }
        let wantedTitle = self.title(title)
        let wantedArtists = artists(artist)
        return candidates.first { candidate in
            self.title(candidate.title) == wantedTitle && !artists(candidate.artist ?? "").isDisjoint(with: wantedArtists)
        }
    }

    /// A title without what doesn't change the recording: a trailing "(feat. …)" or
    /// "(Remastered)", and a " - Remastered 2011" suffix.
    static func title(_ value: String) -> String {
        var result = value
        if let dash = result.range(of: " - ", options: .backwards),
           result[dash.upperBound...].localizedCaseInsensitiveContains("remaster") {
            result.removeSubrange(dash.lowerBound...)
        }
        return CatalogMatcher.normalize(result)
    }

    /// Every artist a credit names, and the whole credit: "Yeat & Drake" is Yeat, Drake, and
    /// "Yeat & Drake". "Florence + the Machine" stays one artist.
    static func artists(_ credit: String) -> Set<String> {
        let whole = StatsCalculator.folded(credit)
        guard !whole.isEmpty else { return [] }
        return LocalTrack.creditedArtists(of: credit)
    }
}

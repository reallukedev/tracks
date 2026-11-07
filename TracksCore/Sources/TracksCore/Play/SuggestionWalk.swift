import Foundation

/// Where the suggestions walk next from the artists just visited.
///
/// Every artist like them goes on the walk, so it can reach the artists past them, but only
/// ones never played are suggested. A long history can have played every artist like your
/// top ones; walking only through new artists would end there, a step out, with almost
/// nothing found. The new ones are walked first, since they're the likeliest to have songs
/// you've never heard.
public enum SuggestionWalk {
    public struct Step<Artist> {
        /// The artists to visit next, never-played ones first, each in the order given.
        public var walk: [Artist]
        /// The never-played ones, to suggest.
        public var new: [Artist]
    }

    /// - Parameters:
    ///   - similar: artists like the ones just visited, the likeliest first.
    ///   - id: an artist's catalog id, to visit each artist once.
    ///   - name: an artist's name, to match against the history.
    ///   - visited: artists already on the walk. The ones taken here are added.
    ///   - heard: every artist the history has, folded.
    ///   - isLeftOut: whether an artist is never to be suggested or walked to: blocked, or
    ///     hidden from suggestions.
    public static func step<Artist, ID: Hashable>(
        from similar: [Artist],
        id: (Artist) -> ID,
        name: (Artist) -> String,
        visited: inout Set<ID>,
        heard: Set<String>,
        isLeftOut: (String) -> Bool
    ) -> Step<Artist> {
        var new: [Artist] = []
        var known: [Artist] = []
        for artist in similar where !isLeftOut(name(artist)) && visited.insert(id(artist)).inserted {
            if heard.contains(StatsCalculator.folded(name(artist))) {
                known.append(artist)
            } else {
                new.append(artist)
            }
        }
        return Step(walk: new + known, new: new)
    }
}

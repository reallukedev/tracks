import Foundation

/// What one merge of a playlist with its Apple Music playlist knows: the songs Apple Music had,
/// the songs here Apple Music calls by another name, and the songs that couldn't be found. Only
/// names that came from Apple Music decide what was taken out there.
public struct AppleMusicMergeLedger: Sendable, Equatable {
    /// Songs, by Apple Music's identity, the Apple Music playlist has had.
    public private(set) var seen: Set<String>
    /// Songs here, by identity, mapped to the identity Apple Music has for them.
    public private(set) var matched: [String: String]
    public private(set) var notFound: Set<String>

    /// Picks up from a link's last merge. A link from before `matched` was kept can't say which
    /// of its `seen` names were Apple Music's, so one missing there but still here is kept and
    /// never taken out, rather than guessed at.
    public init(link: TracksPlaylist.AppleMusicLink, here: Set<String>, inApple: Set<String>) {
        var seen = Set(link.seen)
        var matched = link.matched ?? [:]
        if link.matched == nil {
            for identity in seen where !inApple.contains(identity) && here.contains(identity) {
                matched[identity] = identity
                seen.remove(identity)
            }
        }
        self.seen = seen
        self.matched = matched
        self.notFound = Set(link.notFound)
    }

    /// Forgets the Apple Music songs taken out since the last merge. Returns the songs here,
    /// by identity, to take out with them.
    public mutating func takeOut(keeping inApple: Set<String>) -> Set<String> {
        let gone = seen.subtracting(inApple)
        guard !gone.isEmpty else { return [] }
        seen.subtract(gone)
        let aliases = Set(matched.filter { gone.contains($0.value) }.keys)
        for alias in aliases { matched[alias] = nil }
        // A song here with the same name as a gone one goes too, unless it's matched to an
        // Apple Music song that's still there.
        let sameName = gone.filter { matched[$0] == nil }
        return aliases.union(sameName)
    }

    /// Whether an Apple Music song is new since the last merge, and still to be looked for.
    public func isNew(apple identity: String, here: Set<String>) -> Bool {
        !seen.contains(identity) && !here.contains(identity) && !notFound.contains(identity)
    }

    /// An Apple Music song found as one of yours, which may go by another name here.
    public mutating func found(apple: String, here: String) {
        seen.insert(apple)
        if apple != here { matched[here] = apple }
    }

    /// An Apple Music song looked for and not found.
    public mutating func missing(apple: String) {
        seen.insert(apple)
        notFound.insert(apple)
    }

    /// Whether a song here is still to be added in Apple Music.
    public func needsAdding(here identity: String, inApple: Set<String>) -> Bool {
        !inApple.contains(identity) && !seen.contains(identity) && matched[identity] == nil && !notFound.contains(identity)
    }

    /// A song here added in Apple Music, which may name it differently.
    public mutating func added(here: String, apple: String) {
        found(apple: apple, here: here)
    }

    /// A song here that Apple Music's catalog doesn't have.
    public mutating func notInCatalog(here identity: String) {
        notFound.insert(identity)
    }

    /// Remembers the Apple Music songs that are here at the end of a merge, so one taken out
    /// there later comes out here too.
    public mutating func settle(here: Set<String>, inApple: Set<String>) {
        seen.formUnion(inApple.intersection(here))
    }

    /// The link with this merge's ledger written into it.
    public func written(to link: TracksPlaylist.AppleMusicLink) -> TracksPlaylist.AppleMusicLink {
        var link = link
        link.seen = seen.sorted()
        link.notFound = notFound.sorted()
        link.matched = matched
        return link
    }
}

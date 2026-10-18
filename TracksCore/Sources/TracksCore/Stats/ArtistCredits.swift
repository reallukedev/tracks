import Foundation
import Synchronization

/// One artist a song credits.
public struct ArtistCredit: Sendable, Hashable, Identifiable {
    public enum Role: Sendable, Hashable {
        /// Named in the artist, alone or beside others: "A", "A & B", "A x B".
        case primary
        /// After "feat.", "ft.", "featuring" or "with", in the artist or the title.
        case featured
    }

    /// As written in the credit, trimmed.
    public let name: String
    /// Folded, as ``StatsCalculator/folded(_:)``: what plays are grouped by.
    public let identity: String
    public let role: Role

    public var id: String { identity }

    public init(name: String, role: Role) {
        self.name = name
        self.identity = StatsCalculator.folded(name)
        self.role = role
    }
}

/// Works out everyone a song credits from its artist and title, so a collaboration counts
/// for each artist on it.
///
/// Apple Music writes collaborations as "A & B" or "A, B & C" and puts features in the
/// title: "Song (feat. B)". Last.fm and file tags add "A feat. B", "A x B" and "A; B". Bands
/// whose names hold a separator ("Simon & Garfunkel", "Earth, Wind & Fire") stay whole, from
/// a short list and from the rule that "& the …", "and His Orchestra" and "& Sons" belong to
/// the name before them. When Apple Music's own list of the song's artists is known, it
/// settles what the name alone can't.
public enum ArtistCredits {
    /// Everyone credited: the main artists first, in order, then the featured ones. Empty for
    /// a blank artist. Each artist is credited once, as a main artist if they're one.
    ///
    /// - Parameter catalogArtists: the names on the song's artists in Apple Music. Used only
    ///   when every one of them appears in the artist or title, so a different spelling or a
    ///   wrong match never renames anyone.
    public static func parse(artist: String, title: String = "", catalogArtists: [String]? = nil) -> [ArtistCredit] {
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty else { return [] }
        guard catalogArtists?.isEmpty == false || mayCreditSeveral(artist: artist, title: title) else {
            return single(artist)
        }
        let parsed = split(artist: artist)
        var primary = parsed.primary
        var featured = parsed.featured + titleFeatures(title)

        if let catalog = usable(catalogArtists, artist: artist, title: title) {
            let featuredIdentities = Set(featured.map(StatsCalculator.folded))
            let catalogIdentities = Set(catalog.map(StatsCalculator.folded))
            primary = catalog.filter { !featuredIdentities.contains(StatsCalculator.folded($0)) }
            featured = catalog.filter { featuredIdentities.contains(StatsCalculator.folded($0)) }
                + featured.filter { !catalogIdentities.contains(StatsCalculator.folded($0)) }
            // A catalog that lists only featured artists still leaves the credit a main one.
            if primary.isEmpty { primary = parsed.primary }
        }

        var seen = Set<String>()
        var credits: [ArtistCredit] = []
        for (names, role) in [(primary, ArtistCredit.Role.primary), (featured, .featured)] {
            for name in names {
                let credit = ArtistCredit(name: name, role: role)
                guard !credit.identity.isEmpty, seen.insert(credit.identity).inserted else { continue }
                credits.append(credit)
            }
        }
        return credits
    }

    /// ``parse(artist:title:catalogArtists:)`` from the name alone, remembered, since a history
    /// holds the same songs many times over.
    public static func byName(artist: String, title: String) -> [ArtistCredit] {
        guard mayCreditSeveral(artist: artist, title: title) else { return single(artist) }
        let key = artist + "\u{1F}" + title
        if let known = remembered.withLock({ $0[key] }) { return known }
        let credits = parse(artist: artist, title: title)
        remembered.withLock {
            if $0.count >= 20_000 { $0.removeAll(keepingCapacity: true) }
            $0[key] = credits
        }
        return credits
    }

    private static let remembered = Mutex<[String: [ArtistCredit]]>([:])

    /// Everyone a song credits, with Apple Music's list of its artists when the history has
    /// looked it up, so a page or menu credits a song as the statistics do.
    public static func song(artist: String, title: String) -> [ArtistCredit] {
        guard mayCreditSeveral(artist: artist, title: title),
              let known = CatalogCredits.shared.artists(forSong: HistoryImport.key(title: title, artistName: artist))
        else { return byName(artist: artist, title: title) }
        return parse(artist: artist, title: title, catalogArtists: known)
    }

    /// The first main artist: "Beyoncé" for "Beyoncé & JAY-Z feat. Mara Solís".
    public static func lead(of artist: String) -> String {
        parse(artist: artist).first?.name ?? artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The credit of a name that can't hold more than one artist, without parsing it.
    static func single(_ artist: String) -> [ArtistCredit] {
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? [] : [ArtistCredit(name: name, role: .primary)]
    }

    /// Whether the artist and title could credit more than one artist. Cheap, and true for
    /// some that credit only one ("Featherweight"), which ``parse(artist:title:catalogArtists:)``
    /// then settles.
    public static func mayCreditSeveral(artist: String, title: String = "") -> Bool {
        if mightHold(artist, punctuation: "&,+/;([", wordStarts: "xvfwa", nonASCII: true) {
            let bytes = Array(artist.lowercased().utf8)
            if artistNeedles.contains(where: { contains($0, in: bytes) }) {
                return true
            }
        }
        return mightHold(title, punctuation: "([", wordStarts: "f", nonASCII: false)
            && featureHint(in: title.lowercased())
    }

    /// A quick look at the bytes, since most names hold no separator and Foundation's search
    /// is slow across a whole history: any of `punctuation`, a word starting with one of
    /// `wordStarts`, or (for "×") any non-ASCII byte.
    private static func mightHold(_ text: String, punctuation: StaticString, wordStarts: StaticString, nonASCII: Bool) -> Bool {
        let marks = UnsafeBufferPointer(start: punctuation.utf8Start, count: punctuation.utf8CodeUnitCount)
        let starts = UnsafeBufferPointer(start: wordStarts.utf8Start, count: wordStarts.utf8CodeUnitCount)
        var previous: UInt8 = UInt8(ascii: " ")
        for byte in text.utf8 {
            if marks.contains(byte) || (nonASCII && byte >= 0x80) { return true }
            if previous == UInt8(ascii: " "), starts.contains(byte | 0x20) { return true }
            previous = byte
        }
        return false
    }

    // MARK: - Splitting

    private static func split(artist: String) -> (primary: [String], featured: [String]) {
        var (rest, featured) = bracketFeatures(in: artist, withAnyCase: true)
        // Searched in the name itself: folding can change its length ("İ"), so an index into
        // a folded copy can land elsewhere in the original.
        let padded = rest + " "
        let lowered = padded.lowercased()
        var cut: (marker: Range<String.Index>, dotted: Bool)?
        for marker in bareMarkers where lowered.contains(marker) {
            var searchStart = padded.startIndex
            while let found = padded.range(of: marker, options: .caseInsensitive, range: searchStart..<padded.endIndex) {
                searchStart = found.upperBound
                let after = padded[found.upperBound...].trimmingCharacters(in: .whitespaces)
                // "Little Feat" is a band: an undotted marker needs a name after it.
                if after.isEmpty && !marker.contains(".") { continue }
                if marker == " with ", startsWithBandWord(padded[found.upperBound...]) { continue }
                if cut.map({ found.lowerBound < $0.marker.lowerBound }) ?? true {
                    cut = (found, marker.contains("."))
                }
                break
            }
        }
        if let cut {
            featured += splitList(String(padded[cut.marker.upperBound...]))
            rest = String(padded[..<cut.marker.lowerBound])
        }
        let primary = splitList(rest)
        return (primary.isEmpty ? [artist] : primary, featured)
    }

    /// Featured artists named in the title: "(feat. B)", "[ft. B]", "(with B)", "Song feat. B".
    static func titleFeatures(_ title: String) -> [String] {
        guard featureHint(in: StatsCalculator.folded(title)) else { return [] }
        // "(With Strings)" is part of a title; Spotify-style credits use a lowercase "with".
        var (rest, featured) = bracketFeatures(in: title, withAnyCase: false)
        for marker in [" feat. ", " ft. ", " featuring "] {
            guard let found = rest.range(of: marker, options: .caseInsensitive) else { continue }
            var tail = rest[found.upperBound...]
            if let end = tail.firstIndex(where: { "([".contains($0) }) { tail = tail[..<end] }
            if let dash = tail.range(of: " - ") { tail = tail[..<dash.lowerBound] }
            featured += splitList(String(tail))
            rest = String(rest[..<found.lowerBound])
        }
        return featured
    }

    /// Takes "(feat. B)" and "[with B]" out of `text`, returning what's left and the names.
    private static func bracketFeatures(in text: String, withAnyCase: Bool) -> (rest: String, featured: [String]) {
        guard text.contains(where: { $0 == "(" || $0 == "[" }) else { return (text, []) }
        var rest = ""
        var featured: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "(" || character == "[" else {
                rest.append(character)
                index = text.index(after: index)
                continue
            }
            let close: Character = character == "(" ? ")" : "]"
            let inside = text[text.index(after: index)...]
            let body = inside.drop { $0 == " " }
            guard let marker = bracketMarkers.first(where: { marker in
                      let start = String(body.prefix(marker.count))
                      return marker == "with " && !withAnyCase ? start == marker : start.lowercased() == marker
                  }),
                  let end = inside.firstIndex(of: close)
            else {
                rest.append(character)
                index = text.index(after: index)
                continue
            }
            let namesStart = body.index(body.startIndex, offsetBy: marker.count)
            if namesStart < end {
                featured += splitList(String(text[namesStart..<end]))
            }
            index = text.index(after: end)
        }
        return (rest.trimmingCharacters(in: .whitespaces), featured)
    }

    /// Splits a list of names at its separators, keeping bands whole.
    static func splitList(_ text: String) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let folded = StatsCalculator.folded(text)
        if ArtistCreditNames.bands.contains(folded) { return [text] }
        guard listSeparators.contains(where: folded.contains) || text.contains(" x ") else { return [text] }

        let protected = bandRanges(in: text, folded: folded)
        var cuts: [Range<String.Index>] = []
        for separator in listSeparators + [" x "] where folded.contains(separator) {
            let options: String.CompareOptions = separator == " x " ? [] : .caseInsensitive
            var searchStart = text.startIndex
            while let found = text.range(of: separator, options: options, range: searchStart..<text.endIndex) {
                searchStart = found.upperBound
                guard !protected.contains(where: { $0.overlaps(found) }) else { continue }
                if joiners.contains(separator.lowercased()),
                   startsWithBandWord(text[found.upperBound...]),
                   // Earth, Wind & Fire & The Emotions: the band before is already whole.
                   !protected.contains(where: { $0.upperBound == found.lowerBound }) {
                    continue
                }
                cuts.append(found)
            }
        }
        // Where two overlap, as ", & " and " & " do, the earlier and longer one wins.
        cuts.sort { ($0.lowerBound, text.distance(from: $1.lowerBound, to: $1.upperBound)) < ($1.lowerBound, text.distance(from: $0.lowerBound, to: $0.upperBound)) }
        var pieces: [String] = []
        var start = text.startIndex
        for cut in cuts where cut.lowerBound >= start {
            pieces.append(String(text[start..<cut.lowerBound]))
            start = cut.upperBound
        }
        pieces.append(String(text[start...]))
        return pieces
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")) }
            .filter { !$0.isEmpty }
    }

    /// Where the known bands sit in `text`, matched whole.
    private static func bandRanges(in text: String, folded: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for band in ArtistCreditNames.bands where folded.contains(band) {
            var searchStart = text.startIndex
            while let found = text.range(of: band, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                searchStart = found.upperBound
                let before = found.lowerBound == text.startIndex ? " " : text[text.index(before: found.lowerBound)]
                let after = found.upperBound == text.endIndex ? " " : text[found.upperBound]
                if !before.isLetter, !before.isNumber, !after.isLetter, !after.isNumber {
                    ranges.append(found)
                }
            }
        }
        return ranges
    }

    /// Whether what follows a joiner belongs to the name before it: "& the Machine", "and
    /// His Orchestra", "& Sons". Not when it's an artist of their own, like The Weeknd.
    private static func startsWithBandWord(_ text: Substring) -> Bool {
        let folded = StatsCalculator.folded(String(text))
        guard let word = ArtistCreditNames.bandWords.first(where: { folded.hasPrefix($0) }) else { return false }
        guard word == "the " else { return true }
        return !ArtistCreditNames.theArtists.contains { name in
            folded.hasPrefix(name) && (folded.count == name.count || !folded[folded.index(folded.startIndex, offsetBy: name.count)].isLetter)
        }
    }

    /// Keeps `catalogArtists` only when each of them is named in the artist or title.
    private static func usable(_ catalogArtists: [String]?, artist: String, title: String) -> [String]? {
        let names = (catalogArtists ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        let haystack = StatsCalculator.folded(artist + " " + title)
        return names.allSatisfy { containsWhole(StatsCalculator.folded($0), in: haystack) } ? names : nil
    }

    private static func containsWhole(_ needle: String, in haystack: String) -> Bool {
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let before = found.lowerBound == haystack.startIndex ? " " : haystack[haystack.index(before: found.lowerBound)]
            let after = found.upperBound == haystack.endIndex ? " " : haystack[found.upperBound]
            if !before.isLetter, !before.isNumber, !after.isLetter, !after.isNumber { return true }
            searchStart = haystack.index(after: found.lowerBound)
        }
        return false
    }

    /// Whether a lowercased title might name a featured artist.
    private static func featureHint(in title: String) -> Bool {
        let bytes = Array(title.utf8)
        return titleNeedles.contains { contains($0, in: bytes) }
    }

    private static func contains(_ needle: [UInt8], in bytes: [UInt8]) -> Bool {
        guard needle.count <= bytes.count else { return false }
        for start in 0...(bytes.count - needle.count) where bytes[start] == needle[0] {
            var index = 1
            while index < needle.count, bytes[start + index] == needle[index] { index += 1 }
            if index == needle.count { return true }
        }
        return false
    }

    private static let artistNeedles = (listSeparators + [" x "] + artistHints).map { Array($0.utf8) }
    private static let titleNeedles = titleHints.map { Array($0.utf8) }

    private static let titleHints = ["feat", " ft.", "(ft", "[ft", "(with ", "[with ", "( with ", "( feat"]
    private static let artistHints = ["feat", " ft", "(ft", "[ft", " with ", "(with", "[with"]

    // MARK: - Separators

    /// Between names in a list. " x " is matched separately, lowercase only, so "Lil Nas X &
    /// Jack Harlow" isn't cut after "Lil Nas".
    private static let listSeparators = [", and ", ", & ", " and ", " & ", " + ", " × ", " vs. ", " vs ", " / ", "; ", ", "]
    /// Separators a band's name can carry, which ``startsWithBandWord(_:)`` may overrule.
    private static let joiners: Set<String> = [", and ", ", & ", " and ", " & ", " + "]
    private static let bareMarkers = [" featuring ", " feat. ", " feat ", " ft. ", " ft ", " with "]
    private static let bracketMarkers = ["featuring ", "feat. ", "feat ", "ft. ", "ft ", "with "]
}

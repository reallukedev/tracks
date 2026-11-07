import Foundation

/// Text as search compares it: case and accents aside, apostrophes dropped so "dont" finds
/// "Don't", other punctuation taken as a space so "ac dc" finds "AC/DC", and "&" read as "and".
public enum SearchFolding {
    public static func fold(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in StatsCalculator.folded(text) {
            if apostrophes.contains(character) { continue }
            if character == "&" {
                if !out.isEmpty { out.append(" ") }
                out.append("and")
                pendingSpace = true
                continue
            }
            if character.isLetter || character.isNumber {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "`", "\u{00B4}"]

    /// Whether a typed word is a letter off a word of the name, or the start of one: one
    /// letter wrong, missing, extra or swapped with the next. Only for words of four letters
    /// or more, as a shorter word a letter off matches nearly anything.
    public static func isNear(_ typed: some StringProtocol, _ word: some StringProtocol) -> Bool {
        let typed = Array(typed)
        guard typed.count >= 4 else { return false }
        let word = Array(word)
        // The word itself, or its start as long as what was typed, give or take a letter.
        for length in [typed.count - 1, typed.count, typed.count + 1] where length > 0 && length <= word.count {
            if withinOne(typed, word[..<length]) { return true }
        }
        return false
    }

    /// Optimal string alignment distance of at most one, without working out the whole table.
    private static func withinOne(_ a: [Character], _ b: ArraySlice<Character>) -> Bool {
        let b = Array(b)
        if abs(a.count - b.count) > 1 { return false }
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        if i == a.count && i == b.count { return true }
        if a.count == b.count {
            // One letter wrong, or two side by side swapped.
            if a[(i + 1)...] == b[(i + 1)...] { return true }
            return i + 1 < a.count && a[i] == b[i + 1] && a[i + 1] == b[i] && a[(i + 2)...] == b[(i + 2)...]
        }
        // One letter missing from the shorter.
        return a.count > b.count ? a[(i + 1)...] == b[i...] : a[i...] == b[(i + 1)...]
    }
}

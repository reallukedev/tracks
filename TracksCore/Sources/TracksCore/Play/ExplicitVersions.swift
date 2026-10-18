import Foundation

/// Picks one version of each song when Apple Music offers both an explicit and a clean one.
///
/// Search, an artist's top songs and a lot of playlists list the same song twice, once of each.
/// With explicit songs allowed, the explicit version stands in for its clean twin; without,
/// every explicit item is left out.
public enum ExplicitVersions {
    /// - Parameters:
    ///   - allowsExplicit: the person's setting.
    ///   - isExplicit: whether this version is marked explicit.
    ///   - discriminator: anything else that tells two same-named items apart, such as an
    ///     album's release year. Items with different values are never versions of each other.
    /// - Returns: the items in their original order. Without explicit songs, every explicit
    ///   item goes. With them, a clean item goes only when an explicit twin stands in for it:
    ///   two clean songs of the same name (a studio take and a live one) both stay.
    public static func pick<Item>(
        _ items: [Item],
        allowsExplicit: Bool,
        title: (Item) -> String,
        artist: (Item) -> String,
        isExplicit: (Item) -> Bool,
        discriminator: (Item) -> String = { _ in "" }
    ) -> [Item] {
        guard allowsExplicit else { return items.filter { !isExplicit($0) } }

        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            let key = versionKey(title: title(item), artist: artist(item)) + "\u{1F}" + discriminator(item)
            groups[key, default: []].append(index)
        }
        var dropped = Set<Int>()
        for members in groups.values {
            let explicit = members.filter { isExplicit(items[$0]) }
            let clean = members.filter { !isExplicit(items[$0]) }
            // One clean version goes for each explicit one there is, the earliest first.
            dropped.formUnion(clean.prefix(explicit.count))
        }
        // An explicit twin takes the place of the clean one it replaces, when that came first.
        var result: [Item] = []
        var placed = Set<Int>()
        for (index, item) in items.enumerated() {
            if dropped.contains(index) {
                let key = versionKey(title: title(item), artist: artist(item)) + "\u{1F}" + discriminator(item)
                if let twin = groups[key]?.first(where: { isExplicit(items[$0]) && !placed.contains($0) }) {
                    placed.insert(twin)
                    result.append(items[twin])
                }
                continue
            }
            if isExplicit(item), placed.contains(index) { continue }
            placed.insert(index)
            result.append(item)
        }
        return result
    }

    /// Whether an item may be played at all under the setting.
    public static func allows(isExplicit: Bool, allowsExplicit: Bool) -> Bool {
        allowsExplicit || !isExplicit
    }

    /// Title and artist, folded, with the version markers stores add ("(Clean)",
    /// "[Explicit]", "- Clean Version") taken off.
    public static func versionKey(title: String, artist: String) -> String {
        "\(StatsCalculator.folded(strippingMarkers(title)))\u{1F}\(StatsCalculator.folded(artist))"
    }

    static func strippingMarkers(_ title: String) -> String {
        var result = title
        let markers = ["clean", "explicit", "clean version", "explicit version", "edited", "radio edit"]
        for marker in markers {
            for (open, close) in [("(", ")"), ("[", "]")] {
                result = result.replacingOccurrences(
                    of: "\(open)\(marker)\(close)",
                    with: "",
                    options: [.caseInsensitive]
                )
            }
            result = result.replacingOccurrences(of: " - \(marker)", with: "", options: [.caseInsensitive, .anchored, .backwards])
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

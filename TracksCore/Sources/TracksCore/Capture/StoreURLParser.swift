import Foundation

/// Extracts an Apple Music catalog song ID from an iTunes Store URL.
///
/// Handles `itmss://itunes.com/album?p=<album>&i=<song>` and `https://music.apple.com` links.
/// macOS 27's `playerInfo` no longer has a `Store URL` key, but share links and Music's
/// scripting still use the `i=` parameter.
public enum StoreURLParser {
    public static func catalogSongID(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        guard let items = components.queryItems else { return nil }
        guard let value = items.first(where: { $0.name == "i" })?.value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Catalog IDs are all digits; anything else means we parsed the wrong thing.
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }
}

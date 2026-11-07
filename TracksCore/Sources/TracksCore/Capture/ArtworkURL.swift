import Foundation

/// Whether an image view can fetch an artwork URL.
///
/// For streams (every radio capture on iOS), MusicKit's `Artwork.url(width:height:)` returns
/// `musicKit://artwork/transient/…`, which `AsyncImage` and `NSImage` can't load. Don't store
/// those: the backfill only fills rows with no artwork, so a bad URL stays blank for good.
public enum ArtworkURL {
    public static func isLoadable(_ urlString: String?) -> Bool {
        guard let scheme = urlString.flatMap({ URL(string: $0)?.scheme?.lowercased() })
        else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// The URL if it can be loaded, otherwise nil.
    public static func loadable(_ urlString: String?) -> String? {
        isLoadable(urlString) ? urlString : nil
    }
}


/// Tells Apple Music catalog IDs ("1814555105") from library IDs ("i.aJGY3G9fEGApOQP").
///
/// Catalog endpoints reject a library ID outright, so filter before building a request.
public enum MusicItemIdentity {
    public static func isCatalogID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy(\.isNumber)
    }

    public static func isLibraryID(_ id: String) -> Bool {
        id.hasPrefix("i.") || id.hasPrefix("l.")
    }
}

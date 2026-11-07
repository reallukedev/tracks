import Foundation

/// Turns track metadata into an Apple Music catalog song ID.
///
/// macOS searches for every song. iOS reads the ID off the queue entry, so it only searches
/// for rows a Mac synced before finding theirs. It's declared here, without MusicKit, so the
/// capture pipeline can be tested without a network or a subscription.
public protocol CatalogResolving: Sendable {
    /// Returns the whole match because on macOS it's also the only source of artwork;
    /// `playerInfo` never has any.
    func resolve(_ query: CatalogQuery) async throws -> CatalogCandidate?

    /// Artwork for songs that already have IDs. iOS never searches, so this is where its
    /// artwork comes from. Also backfills older rows.
    func artworkURLs(forSongIDs ids: [String]) async throws -> [String: String]

    /// The station Apple Music most recently played, if any.
    ///
    /// Both platforms only announce a station's name when you tune in. If the app starts
    /// mid-station, this is the only way to name the session instead of calling it "Radio".
    func mostRecentStationName() async throws -> String?
}

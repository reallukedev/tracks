import Foundation

/// Apple Music's live radio stations, the ones every subscriber can tune in to.
public enum AppleMusicStations {
    /// In the order the stations list shows them. Spelled as the platform reports them
    /// ("Apple Música Uno", with the accent), since an exclusion only matches the exact name.
    public static let live = [
        "Apple Music 1",
        "Apple Music Hits",
        "Apple Music Country",
        "Apple Música Uno",
        "Apple Music Club",
        "Apple Music Chill",
    ]

    /// The stations to offer switches for: the live ones first, then every other station
    /// Tracks has heard in the order given, then any excluded name neither mentions, so each
    /// excluded station keeps a switch to turn it back on.
    public static func choices(heard: [String], excluded: Set<String>) -> [String] {
        var seen = Set<String>()
        let known = (live + heard).filter { seen.insert($0).inserted }
        return known + excluded.subtracting(seen).sorted()
    }
}

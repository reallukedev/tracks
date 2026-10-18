import Foundation

extension DemoLibrary {
    /// Where a sample play came from. Songs chosen by a few of the artists play from Your
    /// Music, as if their albums were on a music server of your own, so sample data has both
    /// sources to show apart. Radio is always Apple Music.
    ///
    /// Decided by the play rather than drawn from the seed, so the histories stay as they were.
    public static func source(of play: Play) -> PlaySource {
        guard play.kind == .onDemand, yourMusicArtists.contains(play.artistName) else { return .appleMusic }
        return .yourMusic
    }

    /// Every fourth artist, starting with the second most played.
    private static let yourMusicArtists = Set(
        artistNames.enumerated().filter { $0.offset % 4 == 1 }.map(\.element)
    )
}

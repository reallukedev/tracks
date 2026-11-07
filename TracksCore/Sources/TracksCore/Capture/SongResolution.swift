import Foundation

/// The result of turning what's playing into an Apple Music catalog song ID.
///
/// iOS reads the ID off the player; macOS has to match metadata against a catalog search.
/// `method` and `diagnostics` record how, so a failed capture can be debugged.
public struct SongResolution: Sendable {
    public let songID: String?
    /// How the answer was reached, or why it could not be.
    public let method: String
    public let diagnostics: [(key: String, value: String)]

    public init(
        songID: String?,
        method: String,
        diagnostics: [(key: String, value: String)] = []
    ) {
        self.songID = songID
        self.method = method
        self.diagnostics = diagnostics
    }

    public static func unavailable(_ reason: String) -> SongResolution {
        SongResolution(songID: nil, method: "unresolved", diagnostics: [("reason", reason)])
    }
}

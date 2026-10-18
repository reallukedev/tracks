import Foundation

/// Where a play's music came from: Apple Music (the Music app, or Tracks’ own Apple Music
/// player), or Your Music, the files and servers Tracks plays itself.
///
/// Stored on a ``Capture`` as its raw value. Plays kept before Tracks knew the difference have
/// none, and count as Apple Music, which is all Tracks could hear then.
public enum PlaySource: String, Sendable, CaseIterable, Codable {
    case appleMusic
    case yourMusic

    /// The key Tracks’ own player for Your Music sets in an observation's raw fields, and the
    /// value that marks it.
    public static let observationKey = "source"
    public static let yourMusicMarker = "Your Music"

    /// A stored value read back: nil, or anything this version doesn't know, is Apple Music.
    public init(stored rawValue: String?) {
        self = rawValue.flatMap(PlaySource.init(rawValue:)) ?? .appleMusic
    }

    /// Where an observed song is playing from. Only Tracks’ player for Your Music says; every
    /// other observation comes from Apple Music's players.
    public init(observation: NowPlayingObservation) {
        self = observation.rawFields[Self.observationKey] == Self.yourMusicMarker ? .yourMusic : .appleMusic
    }
}

/// Which plays the statistics count, when the person has asked to see Apple Music and Your
/// Music apart.
public enum SourceScope: String, Sendable, CaseIterable, Identifiable, Codable {
    case all
    case appleMusic
    case yourMusic

    public var id: String { rawValue }

    /// Where the scope on show is remembered.
    public static let storageKey = "statsSourceScope"
    /// Where the setting that offers the scope is remembered. Off unless turned on.
    public static let separatesKey = "separatesMusicSources"

    public func includes(_ source: PlaySource) -> Bool {
        switch self {
        case .all: true
        case .appleMusic: source == .appleMusic
        case .yourMusic: source == .yourMusic
        }
    }

    /// The scope that applies: everything unless the setting is on and there's something of
    /// Your Music's to tell apart.
    public static func effective(_ chosen: SourceScope, separates: Bool, hasYourMusic: Bool) -> SourceScope {
        separates && hasYourMusic ? chosen : .all
    }
}

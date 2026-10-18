import Foundation
import SwiftUI
import MusicKit
import TracksCore

/// The Play tab's settings, by defaults key. Views read them with `@AppStorage` so they redraw;
/// the player reads them at the moment it needs them.
enum PlayPreferences {
    /// Whether explicit songs play. On by default, as in Music.
    static let allowsExplicitKey = "playAllowsExplicit"
    static let transitionKey = "playTransition"
    static let crossfadeSecondsKey = "playCrossfadeSeconds"
    static let layoutKey = "playLayout"
    /// Whether Tracks Radio is offered. On by default.
    static let tracksRadioKey = "tracksRadioIsOn"
    static let radioTuningKey = "tracksRadioTuning"
    /// Where a song's Play button outside the Play tab sends it. See ``SongDestination``.
    static let songDestinationKey = "playSongDestination"

    static let defaultCrossfadeSeconds: Double = 6
    static let crossfadeRange: ClosedRange<Double> = 1...12

    static var allowsExplicit: Bool {
        UserDefaults.standard.object(forKey: allowsExplicitKey) as? Bool ?? true
    }

    static var isTracksRadioOn: Bool {
        UserDefaults.standard.object(forKey: tracksRadioKey) as? Bool ?? true
    }

    /// Tracks Radio from your own music starts with songs already on this iPhone and gets its
    /// new finds ready behind them. On by default.
    static let radioDownloadsFirstKey = "tracksRadioDownloadsFirst"

    static var radioDownloadsFirst: Bool {
        UserDefaults.standard.object(forKey: radioDownloadsFirstKey) as? Bool ?? true
    }

    /// Louder at Speed: the music follows the car's speed while driving. Off by default.
    static let volumeFollowsSpeedKey = "playVolumeFollowsSpeed"

    static var volumeFollowsSpeed: Bool {
        UserDefaults.standard.bool(forKey: volumeFollowsSpeedKey)
    }

    /// How much Louder at Speed changes the music. Moderate by default.
    static let speedVolumeAmountKey = "playSpeedVolumeAmount"

    static var speedVolumeAmount: SpeedVolumeAmount {
        UserDefaults.standard.string(forKey: speedVolumeAmountKey).flatMap(SpeedVolumeAmount.init) ?? .moderate
    }

    /// Whether anything needs to know when you're driving: Tracks Radio playing for the road,
    /// or Louder at Speed.
    static var noticesDriving: Bool {
        radioNoticesDriving || volumeFollowsSpeed
    }

    /// Shaking iPhone plays a song Tracks thinks you'd like, then Tracks Radio. On by default.
    static let shakeToPlayKey = "shakeToPlay"

    static var shakeToPlay: Bool {
        UserDefaults.standard.object(forKey: shakeToPlayKey) as? Bool ?? true
    }

    /// Tracks Radio's new finds are downloaded to play, and the download removed once they've
    /// played, unless you keep them. Off by default.
    static let radioDeletesAfterPlayingKey = "tracksRadioDeletesAfterPlaying"

    static var radioDeletesAfterPlaying: Bool {
        UserDefaults.standard.bool(forKey: radioDeletesAfterPlayingKey)
    }

    /// Once the queue runs out, songs like the last few played carry on, as Music's Autoplay
    /// does. On by default.
    static let autoplayKey = "playAutoplay"

    static var autoplay: Bool {
        UserDefaults.standard.object(forKey: autoplayKey) as? Bool ?? true
    }

    static var radioTuning: RadioTuning {
        RadioTuning(stored: UserDefaults.standard.string(forKey: radioTuningKey) ?? "")
    }

    static var transition: SongTransition {
        UserDefaults.standard.string(forKey: transitionKey).flatMap(SongTransition.init(rawValue:)) ?? .off
    }

    static var crossfadeSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: crossfadeSecondsKey)
        return stored > 0 ? min(max(stored, crossfadeRange.lowerBound), crossfadeRange.upperBound) : defaultCrossfadeSeconds
    }

    #if os(iOS)
    /// The transition for MusicKit's player. Songs next to each other on one album always
    /// play gaplessly; the player doesn't fade those. The Mac's MusicKit player has no
    /// transitions.
    static var musicTransition: MusicPlayer.Transition {
        switch transition {
        case .crossfade: .crossfade(duration: crossfadeSeconds)
        case .off: MusicPlayer.Transition.none
        }
    }
    #endif

    /// Keeps only the versions the setting allows: the explicit one of a song with both when
    /// explicit songs are on, the clean one when they're off.
    static func versions(of songs: [Song], allowsExplicit: Bool = allowsExplicit) -> [Song] {
        ExplicitVersions.pick(
            songs,
            allowsExplicit: allowsExplicit,
            title: \.title,
            artist: \.artistName,
            isExplicit: { $0.contentRating == .explicit }
        )
    }

    static func versions(of albums: [Album], allowsExplicit: Bool = allowsExplicit) -> [Album] {
        ExplicitVersions.pick(
            albums,
            allowsExplicit: allowsExplicit,
            title: \.title,
            artist: \.artistName,
            isExplicit: { $0.contentRating == .explicit },
            // Artists reuse titles ("Weezer", "Greatest Hits"); a version shares its year.
            discriminator: { album in album.releaseDate.map { "\(Calendar.current.component(.year, from: $0))" } ?? "" }
        )
    }
}

/// What happens between one song and the next.
///
/// Music's AutoMix, which beat-matches songs like a DJ, isn't open to other apps: MusicKit's
/// player offers a crossfade or nothing.
enum SongTransition: String, CaseIterable, Identifiable {
    /// The default: each song ends before the next starts, as recorded.
    case off
    case crossfade

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .off: "None"
        case .crossfade: "Crossfade"
        }
    }
}

/// Where songs played from Summary, History and Charts go: Tracks’ own player, which keeps every
/// play, or Apple Music. The Play tab always plays in Tracks.
enum SongDestination: String, CaseIterable, Identifiable {
    case tracks
    case appleMusic

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .tracks: "Tracks"
        case .appleMusic: "Apple Music"
        }
    }
}

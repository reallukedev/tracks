import SwiftUI
import TracksCore

/// Where Play's music comes from: Apple Music's catalog, or music you own, as files on this
/// iPhone and on your own music servers.
nonisolated enum MusicSource: String, CaseIterable, Identifiable, Sendable {
    case appleMusic
    case yourMusic

    var id: String { rawValue }

    static let storageKey = "musicSource"

    static var current: MusicSource {
        UserDefaults.standard.string(forKey: storageKey).flatMap(MusicSource.init(rawValue:)) ?? .appleMusic
    }

    var title: LocalizedStringKey {
        switch self {
        case .appleMusic: "Apple Music"
        case .yourMusic: "Your Music"
        }
    }

    var symbol: String {
        switch self {
        case .appleMusic: "music.note"
        case .yourMusic: "externaldrive.fill"
        }
    }

    /// The title as a plain string, for a row's value.
    var name: String {
        switch self {
        case .appleMusic: String(localized: "Apple Music")
        case .yourMusic: String(localized: "Your Music")
        }
    }
}

/// Automatic Downloads: songs from your servers come down to this iPhone as you play or add
/// them, so they play at once, and with no connection, from then on.
enum AutomaticDownloads {
    static let storageKey = "yourMusicAutomaticDownloads"

    /// On unless turned off.
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
    }
}

/// How good a song from your servers is: as it is on the server, or a smaller copy the server
/// makes as it sends it. Named as Apple Music names its own choices. One setting each for
/// streaming on Wi-Fi and on cellular (the Mac has one for every network), and one for new
/// downloads.
enum StreamQuality: String, CaseIterable, Identifiable {
    /// The file as it is on the server: FLAC stays FLAC.
    case original
    /// An MP3 at 320 kbps, made by the server.
    case high
    /// An MP3 at 128 kbps, made by the server.
    case dataSaver

    var id: String { rawValue }

    /// Streaming on cellular. The first streaming setting, so it keeps the first key.
    static let cellularKey = "yourMusicStreamQuality"
    /// Streaming on Wi-Fi, and on the Mac on any network.
    static let wiFiKey = "yourMusicStreamQualityWiFi"
    /// New downloads. Downloads already made stay as they are.
    static let downloadKey = "yourMusicDownloadQuality"

    static var cellular: StreamQuality { stored(cellularKey) }
    static var wiFi: StreamQuality { stored(wiFiKey) }
    static var download: StreamQuality { stored(downloadKey) }

    /// The setting for streaming now: the Mac's one setting; on iPhone the cellular one on an
    /// expensive network (cellular, or a phone's hotspot), otherwise Wi-Fi's.
    static func streaming(onExpensiveNetwork expensive: Bool) -> (quality: StreamQuality, network: StreamNetwork) {
        #if os(macOS)
        (wiFi, .any)
        #else
        expensive ? (cellular, .cellular) : (wiFi, .wifi)
        #endif
    }

    private static func stored(_ key: String) -> StreamQuality {
        UserDefaults.standard.string(forKey: key).flatMap(StreamQuality.init(rawValue:)) ?? .original
    }

    var title: LocalizedStringKey {
        switch self {
        case .original: "Original"
        case .high: "High Quality"
        case .dataSaver: "High Efficiency"
        }
    }

    /// Under each choice in its menu.
    var subtitle: LocalizedStringKey {
        switch self {
        case .original: "As it is on your server"
        case .high: "MP3 at 320 kbps"
        case .dataSaver: "MP3 at 128 kbps, the smallest"
        }
    }

    /// For the server's stream: nil keeps the original.
    var maxBitRate: Int? {
        switch self {
        case .original: nil
        case .high: 320
        case .dataSaver: 128
        }
    }
}

/// A quality setting's choices, each with what it means under it, and the row showing the
/// choice's short name.
struct StreamQualityPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: StreamQuality

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(StreamQuality.allCases) { quality in
                VStack(alignment: .leading) {
                    Text(quality.title)
                    Text(quality.subtitle)
                }
                .tag(quality)
            }
        } currentValueLabel: {
            Text(selection.title)
        }
    }
}

/// Whether Your Music suggests songs you don't have.
enum SuggestionMode: String, CaseIterable, Identifiable {
    /// Suggestions found in your music, on your servers or in Lidarr, including ones Lidarr is still getting.
    case everything
    /// Only suggestions you can play or get: in your music, on your server or in Lidarr.
    case onlyYours
    /// No suggestions: your library, and nothing else.
    case off

    var id: String { rawValue }

    static let storageKey = "yourMusicSuggestions"

    static var current: SuggestionMode {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SuggestionMode.init(rawValue:)) ?? .everything
    }

    var title: LocalizedStringKey {
        switch self {
        case .everything: "Everything"
        case .onlyYours: "Only Music I Have"
        case .off: "Off"
        }
    }
}

/// Whether a song you've been suggested can play, in Your Music.
/// What's known of one song from outside your music, observed on its own so its rows redraw
/// only when it's answered.
@MainActor
@Observable
final class SongAnswer {
    var state: SongAvailability?
    /// The look it's from. See ``YourMusic/availabilityGeneration``.
    @ObservationIgnored var generation = -1
}

enum SongAvailability: Equatable {
    /// Still being looked for.
    case checking
    /// In your music: a file, a download, or a song on your server.
    case playable(LocalTrack)
    /// Lidarr has its file; your server just hasn't synced it yet.
    case inLidarr(album: String)
    /// Lidarr follows its album and is looking for it.
    case comingFromLidarr
    case unavailable

    var track: LocalTrack? {
        if case .playable(let track) = self { return track }
        return nil
    }

    /// Shown under Only Music I Have: everything but what can't be had.
    var isYours: Bool {
        switch self {
        case .checking, .playable, .inLidarr: true
        case .comingFromLidarr, .unavailable: false
        }
    }

    /// Why a song that can't play doesn't, for a moment's message.
    var message: String? {
        switch self {
        case .checking: String(localized: "Still Looking for This Song")
        case .playable: nil
        case .inLidarr: String(localized: "In Lidarr: Download It to Play")
        case .comingFromLidarr: String(localized: "Lidarr Is Getting This Song")
        case .unavailable: String(localized: "This Song Isn't Available")
        }
    }
}

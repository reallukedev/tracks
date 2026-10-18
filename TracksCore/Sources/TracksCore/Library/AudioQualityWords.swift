import Foundation

/// The words for Your Music's quality settings: streaming on Wi-Fi and cellular (one setting
/// on the Mac), Download Quality, and Show Audio Quality. A bit rate is the smaller copy a
/// setting asks the server for; nil is the original file.
public enum AudioQualityWords {
    /// iPhone's footer under Downloads and Streaming: what downloads do, how songs stream on
    /// each network, and what new downloads are.
    public static func downloadsFooter(automatic: Bool, wiFi: Int?, cellular: Int?, download: Int?) -> String {
        let downloads = automatic
            ? String(localized: "Songs you play or add from your servers download to this iPhone, to play with no connection.")
            : String(localized: "Songs download only when you ask.")
        let streaming: String = switch (wiFi, cellular) {
        case (nil, nil): String(localized: "Songs stream as they are on your server, FLAC included.")
        case (nil, _?): String(localized: "On Wi-Fi, songs stream as they are on your server. On cellular, it sends a smaller MP3.")
        case (_?, nil): String(localized: "On Wi-Fi, your server sends a smaller MP3. On cellular, songs stream as they are.")
        case (_?, _?): String(localized: "Your server sends a smaller MP3 as songs stream.")
        }
        return [downloads, streaming, downloadDetail(download)].joined(separator: " ")
    }

    /// The Mac's detail under Streaming.
    public static func streamingDetail(_ bitRate: Int?) -> String {
        guard let bitRate else { return String(localized: "Songs stream as they are on your server, FLAC included.") }
        return String(localized: "Your server sends an MP3 at \(kbps(bitRate)) as songs stream.")
    }

    /// What new downloads are, and that the ones already made stay as they are.
    public static func downloadDetail(_ bitRate: Int?) -> String {
        guard let bitRate else { return String(localized: "Downloads are the original files.") }
        return String(localized: "New downloads are MP3s at \(kbps(bitRate)). Songs already downloaded stay as they are.")
    }

    /// What Show Audio Quality shows, on and off.
    public static func showsAudioQuality(_ isShown: Bool) -> String {
        #if os(macOS)
        isShown
            ? String(localized: "The player shows the quality you’re hearing, such as Lossless or Dolby Atmos. Click it to see why.")
            : String(localized: "The player doesn’t show the quality you’re hearing.")
        #else
        isShown
            ? String(localized: "Now Playing shows the quality you’re hearing, such as Lossless or Dolby Atmos. Tap it to see why.")
            : String(localized: "Now Playing doesn’t show the quality you’re hearing.")
        #endif
    }

    /// Apple Music's quality row: what's playing, or that nothing from Apple Music is.
    public static func appleMusicNowPlaying(_ quality: AudioQuality?) -> String {
        quality?.label ?? String(localized: "Not Playing")
    }

    /// Where Apple Music's quality is chosen. MusicKit plays at Music's settings and offers no
    /// way to change them, so Tracks says where they are rather than showing controls that
    /// couldn't work.
    public static var appleMusicWhere: String {
        #if os(macOS)
        String(localized: "Tracks plays Apple Music at the quality set for Music. Choose Lossless and Dolby Atmos in Music ▸ Settings ▸ Playback.")
        #else
        String(localized: "Tracks plays Apple Music at the quality set for Music. Choose Lossless, Dolby Atmos, and the quality on Wi-Fi, on cellular and for downloads in Settings ▸ Apps ▸ Music ▸ Audio Quality.")
        #endif
    }

    private static func kbps(_ rate: Int) -> String {
        String(rate) + " kbps"
    }
}

import Testing
import Foundation
@testable import TracksCore

/// The words under Your Music's quality settings follow each choice, and say that downloads
/// already made are left as they are.
@Suite("Audio quality words")
struct AudioQualityWordsTests {
    @Test("with everything original, the footer says songs stream and download as they are")
    func allOriginal() {
        #expect(AudioQualityWords.downloadsFooter(automatic: true, wiFi: nil, cellular: nil, download: nil)
            == "Songs you play or add from your servers download to this iPhone, to play with no connection. Songs stream as they are on your server, FLAC included. Downloads are the original files.")
    }

    @Test("the streaming sentence follows each network's choice", arguments: [
        (Int?.none, Int?.some(128), "On Wi-Fi, songs stream as they are on your server. On cellular, it sends a smaller MP3."),
        (320, nil, "On Wi-Fi, your server sends a smaller MP3. On cellular, songs stream as they are."),
        (320, 128, "Your server sends a smaller MP3 as songs stream."),
    ])
    func streaming(wiFi: Int?, cellular: Int?, sentence: String) {
        let footer = AudioQualityWords.downloadsFooter(automatic: false, wiFi: wiFi, cellular: cellular, download: nil)
        #expect(footer == "Songs download only when you ask. \(sentence) Downloads are the original files.")
    }

    @Test("a smaller Download Quality leaves the downloads already made alone")
    func downloadQuality() {
        #expect(AudioQualityWords.downloadDetail(128) == "New downloads are MP3s at 128 kbps. Songs already downloaded stay as they are.")
        #expect(AudioQualityWords.streamingDetail(320) == "Your server sends an MP3 at 320 kbps as songs stream.")
    }

    @Test("Apple Music's row says what's playing, and the footer where its quality is chosen")
    func appleMusic() {
        #expect(AudioQualityWords.appleMusicNowPlaying(AudioQuality(appleMusic: .dolbyAtmos)) == "Dolby Atmos")
        #expect(AudioQualityWords.appleMusicNowPlaying(nil) == "Not Playing")
        #expect(AudioQualityWords.appleMusicWhere.contains("Settings ▸"))
    }

    @Test("Show Audio Quality says what it shows, and what turning it off hides")
    func showsAudioQuality() {
        #expect(AudioQualityWords.showsAudioQuality(true).contains("Lossless or Dolby Atmos"))
        #expect(AudioQualityWords.showsAudioQuality(false).hasSuffix("doesn’t show the quality you’re hearing."))
    }
}

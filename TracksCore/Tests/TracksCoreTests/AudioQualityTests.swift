import Testing
import Foundation
@testable import TracksCore

/// What the quality badge says a song is playing at: a file, a download, or a stream on Wi-Fi
/// or cellular, and whether the server made a smaller copy or sent the original. It must never
/// claim more than is known.
@Suite("Audio quality")
struct AudioQualityTests {
    private let flac = AudioFormat(codec: "FLAC", sampleRate: 44_100, bitDepth: 16)
    private let hiRes = AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 24)
    private let mp3At320 = AudioFormat(codec: "MP3", sampleRate: 44_100, bitRate: 320)
    private let mp3At192 = AudioFormat(codec: "MP3", sampleRate: 44_100, bitRate: 192)
    private let mp3At128 = AudioFormat(codec: "MP3", sampleRate: 44_100, bitRate: 128)

    // MARK: - Files

    @Test("a file plays as it is, and says so")
    func file() throws {
        let quality = try #require(AudioQuality(LocalPlayback(route: .file, original: hiRes)))
        #expect(quality.tier == .hiResLossless)
        #expect(quality.label == "Hi-Res Lossless")
        #expect(quality.showsWaveform)
        #expect(quality.source == .thisDevice)
        #expect(quality.reason == .file)
        #expect(quality.formatDetail == "FLAC 24-bit/96 kHz")
    }

    @Test("a file with no known format shows nothing")
    func unknownFile() {
        #expect(AudioQuality(LocalPlayback(route: .file, original: nil)) == nil)
    }

    // MARK: - Downloads

    @Test("an older download, from before the setting, is the original")
    func olderDownload() throws {
        let quality = try #require(AudioQuality(LocalPlayback(route: .downloaded(requestedBitRate: nil), original: flac)))
        #expect(quality.label == "Lossless")
        #expect(quality.source == .downloaded)
        #expect(quality.reason == .original(.download))
        #expect(quality.reasonLine == "Downloaded as the original file.")
    }

    @Test("a download made smaller is the copy, not the original")
    func convertedDownload() throws {
        let quality = try #require(AudioQuality(LocalPlayback(
            route: .downloaded(requestedBitRate: 128), original: flac, actual: mp3At128
        )))
        #expect(quality.tier == .compressed)
        #expect(quality.label == "MP3 · 128 kbps")
        #expect(quality.showsWaveform == false)
        #expect(quality.reason == .converted(.download, bitRate: 128))
    }

    @Test("a smaller download not yet looked at shows nothing, rather than the original's format")
    func convertedDownloadNotYetKnown() {
        #expect(AudioQuality(LocalPlayback(route: .downloaded(requestedBitRate: 128), original: flac)) == nil)
    }

    @Test("a server that couldn't make a smaller download sent the original, and the badge says so")
    func downloadServerSentOriginal() throws {
        let quality = try #require(AudioQuality(LocalPlayback(
            route: .downloaded(requestedBitRate: 128), original: flac, actual: AudioFormat(codec: "FLAC", sampleRate: 44_100)
        )))
        #expect(quality.label == "Lossless")
        #expect(quality.reason == .serverSentOriginal(.download, bitRate: 128))
        #expect(quality.reasonLine == "Your server sent the original file instead of a 128 kbps copy.")
    }

    // MARK: - Streams

    @Test("the original stream on Wi-Fi shows the song's format straight away")
    func originalOnWiFi() throws {
        let quality = try #require(AudioQuality(LocalPlayback(
            route: .stream(server: "Octo", network: .wifi, requestedBitRate: nil), original: flac
        )))
        #expect(quality.label == "Lossless")
        #expect(quality.source == .streaming(server: "Octo"))
        #expect(quality.factsLine == "Streaming from Octo · FLAC 16-bit/44.1 kHz")
        #expect(quality.reasonLine == "Your Wi-Fi setting streams the original file.")
    }

    @Test("a stream converted on cellular is the copy's format, once heard")
    func convertedOnCellular() throws {
        let playback = LocalPlayback(route: .stream(server: "Octo", network: .cellular, requestedBitRate: 320), original: hiRes)
        #expect(AudioQuality(playback) == nil, "not known until the player has heard it")

        var heard = playback
        heard.actual = AudioFormat(codec: "MP3", sampleRate: 44_100, bitRate: 319)
        let quality = try #require(AudioQuality(heard))
        #expect(quality.label == "MP3 · 320 kbps")
        #expect(quality.spokenLabel == "MP3, 320 kilobits a second")
        #expect(quality.factsLine == "Streaming from Octo")
        #expect(quality.reasonLine == "Your cellular setting streams at 320 kbps.")
    }

    @Test("a server that won't stream a copy bigger than its source shows the rate it sent")
    func cappedCopy() throws {
        let quality = try #require(AudioQuality(LocalPlayback(
            route: .stream(server: "Octo", network: .cellular, requestedBitRate: 320),
            original: AudioFormat(codec: "AAC", bitRate: 256),
            actual: AudioFormat(codec: "MP3", sampleRate: 44_100, bitRate: 256)
        )))
        #expect(quality.label == "MP3 · 256 kbps")
    }

    @Test("a server that can't convert streams the original, and the badge never claims the copy")
    func streamServerSentOriginal() throws {
        let quality = try #require(AudioQuality(LocalPlayback(
            route: .stream(server: "Octo", network: .cellular, requestedBitRate: 128),
            original: flac,
            actual: AudioFormat(codec: "FLAC", sampleRate: 44_100)
        )))
        #expect(quality.label == "Lossless")
        #expect(quality.reason == .serverSentOriginal(.stream(.cellular), bitRate: 128))
    }

    @Test("an MP3 already under the setting streams as it is")
    func alreadySmaller() throws {
        let quality = try #require(AudioQuality(LocalPlayback(
            route: .stream(server: "Octo", network: .wifi, requestedBitRate: 320), original: mp3At192, actual: mp3At192
        )))
        #expect(quality.label == "MP3 · 192 kbps")
        #expect(quality.reason == .alreadySmaller(.stream(.wifi), bitRate: 320))
    }

    @Test("an MP3 bigger than the setting, shrunk to it, is converted")
    func mp3MadeSmaller() throws {
        let quality = try #require(AudioQuality(LocalPlayback(
            route: .stream(server: "Octo", network: .cellular, requestedBitRate: 128), original: mp3At320, actual: mp3At128
        )))
        #expect(quality.label == "MP3 · 128 kbps")
        #expect(quality.reason == .converted(.stream(.cellular), bitRate: 128))
    }

    // MARK: - Apple Music

    @Test("Apple Music's variants read as Music names them", arguments: [
        (AppleMusicVariant.lossless, "Lossless", true),
        (.hiResLossless, "Hi-Res Lossless", true),
        (.dolbyAtmos, "Dolby Atmos", false),
        (.dolbyAudio, "Dolby Audio", false),
        (.spatialAudio, "Spatial Audio", false),
        (.aac, "AAC", false),
    ])
    func appleMusic(variant: AppleMusicVariant, label: String, waveform: Bool) {
        let quality = AudioQuality(appleMusic: variant)
        #expect(quality.label == label)
        #expect(quality.showsWaveform == waveform)
        #expect(quality.source == .appleMusic)
        #expect(quality.sourceLine == "Apple Music")
    }

    @Test("Apple Music's lossless says the most it can be")
    func appleMusicDetail() {
        #expect(AudioQuality(appleMusic: .lossless).factsLine == "Apple Music · ALAC up to 24-bit/48 kHz")
        #expect(AudioQuality(appleMusic: .aac).formatDetail == nil)
    }

    // MARK: - Reading a decoder's format

    @Test("a decoder's format ids become the formats Tracks names")
    func fromDecoder() throws {
        let flac = try #require(AudioFormat(formatID: 0x664C_6143, sampleRate: 96_000, formatFlags: 3))
        #expect(flac == AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 24))
        let mp3 = try #require(AudioFormat(formatID: 0x2E6D_7033, sampleRate: 44_100, bitsPerSecond: 320_000))
        #expect(mp3 == AudioFormat(codec: "MP3", sampleRate: 44_100, bitRate: 320))
        #expect(AudioFormat(formatID: 0x6161_6320, sampleRate: 44_100)?.codec == "AAC")
        #expect(AudioFormat(formatID: 0x7A7A_7A7A, sampleRate: 44_100) == nil)
    }

    @Test("the song's own description wins when the codec agrees, with gaps filled")
    func settled() {
        let tagged = AudioFormat(codec: "FLAC", bitDepth: 24)
        let heard = AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 16)
        #expect(AudioFormat.settled(actual: heard, original: tagged) == AudioFormat(codec: "FLAC", sampleRate: 96_000, bitDepth: 24))
        #expect(AudioFormat.settled(actual: mp3At128, original: flac) == mp3At128)
        #expect(AudioFormat.settled(actual: nil, original: flac) == flac)
    }
}

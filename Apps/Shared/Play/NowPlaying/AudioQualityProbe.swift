import AVFoundation
import TracksCore

/// Reads what a piece of audio really is, from its first audio track: the codec, the sample
/// rate, a lossless file's bit depth and a compressed one's bit rate. It's how Tracks knows
/// whether a server made the smaller copy it was asked for or sent the original, so the
/// quality badge never claims a copy that didn't arrive.
nonisolated enum AudioQualityProbe {
    @concurrent
    static func format(of url: URL) async -> AudioFormat? {
        await format(of: AVURLAsset(url: url))
    }

    /// The asset the player is playing: its tracks load once, for both.
    @concurrent
    static func format(of asset: AVURLAsset) async -> AudioFormat? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let (descriptions, dataRate) = try? await track.load(.formatDescriptions, .estimatedDataRate),
              let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return nil }
        return AudioFormat(
            formatID: basic.mFormatID,
            sampleRate: basic.mSampleRate,
            formatFlags: basic.mFormatFlags,
            bitsPerChannel: basic.mBitsPerChannel,
            bitsPerSecond: Double(dataRate)
        )
    }
}

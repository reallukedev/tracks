import Foundation

/// How a song of yours reaches the player: the file on this device, a download, or a server's
/// stream. The player notes it as each song loads, and ``AudioQuality`` reads what's playing
/// from it.
public struct LocalPlayback: Sendable, Hashable {
    public enum Route: Sendable, Hashable {
        /// A file on this device, played as it is.
        case file
        /// Downloaded to this device. The bit rate is what the download asked the server for;
        /// nil asked for the original file, as every download did before there was a choice.
        case downloaded(requestedBitRate: Int?)
        /// Streamed from a server, by its name, under the setting for the network it started on.
        /// A bit rate asks the server for a smaller copy; nil asks for the original file.
        case stream(server: String, network: StreamNetwork, requestedBitRate: Int?)
    }

    public var route: Route
    /// The song's own format, as its file or its server describes it.
    public var original: AudioFormat?
    /// What the audio turned out to be: the downloaded file's, or what the player found in the
    /// stream once it loaded. This is what settles whether a server made a smaller copy.
    public var actual: AudioFormat?

    public init(route: Route, original: AudioFormat?, actual: AudioFormat? = nil) {
        self.route = route
        self.original = original
        self.actual = actual
    }
}

/// Which streaming setting applies: the iPhone's for Wi-Fi or cellular, or the Mac's one.
public enum StreamNetwork: Sendable, Hashable {
    case wifi
    case cellular
    /// The Mac, which has one setting for every network.
    case any
}

/// What Apple Music says it's playing. The app maps MusicKit's `AudioVariant` onto this, so the
/// words can be tested without MusicKit.
public enum AppleMusicVariant: Sendable, Hashable, CaseIterable {
    case lossless
    case hiResLossless
    case dolbyAtmos
    case dolbyAudio
    case spatialAudio
    /// Compressed stereo: AAC.
    case aac
}

/// What's playing, and how well: the badge between Now Playing's times, and the few lines it
/// opens to. Worked out from what's known, never guessed: a stream the server was asked to
/// shrink has no quality until the player has heard what arrived.
public struct AudioQuality: Sendable, Hashable {
    public enum Tier: Sendable, Hashable {
        case hiResLossless
        case lossless
        case dolbyAtmos
        case dolbyAudio
        case spatialAudio
        /// Compressed: AAC, MP3, Opus and the like.
        case compressed
    }

    public enum Source: Sendable, Hashable {
        case appleMusic
        /// A file on this device.
        case thisDevice
        case downloaded
        case streaming(server: String)
    }

    /// How a song of yours came to be at this quality.
    public enum Via: Sendable, Hashable {
        case download
        case stream(StreamNetwork)
    }

    public enum Reason: Sendable, Hashable {
        /// Apple Music plays at the quality set for Music.
        case appleMusic
        /// Files play as they are.
        case file
        /// Asked for, and got, the original file.
        case original(Via)
        /// The server made a smaller copy, at this many kilobits a second.
        case converted(Via, bitRate: Int)
        /// Asked for a smaller copy, but the original is already no bigger.
        case alreadySmaller(Via, bitRate: Int)
        /// Asked for a smaller copy, and the server sent the original.
        case serverSentOriginal(Via, bitRate: Int)
    }

    public let tier: Tier
    /// Your music's format. Nil for Apple Music, which doesn't say more than its variant.
    public let format: AudioFormat?
    public let source: Source
    public let reason: Reason

    public init(tier: Tier, format: AudioFormat?, source: Source, reason: Reason) {
        self.tier = tier
        self.format = format
        self.source = source
        self.reason = reason
    }

    // MARK: - Working it out

    /// What Apple Music is playing.
    public init(appleMusic variant: AppleMusicVariant) {
        let tier: Tier = switch variant {
        case .lossless: .lossless
        case .hiResLossless: .hiResLossless
        case .dolbyAtmos: .dolbyAtmos
        case .dolbyAudio: .dolbyAudio
        case .spatialAudio: .spatialAudio
        case .aac: .compressed
        }
        self.init(tier: tier, format: nil, source: .appleMusic, reason: .appleMusic)
    }

    /// What a song of yours is playing at, or nil while that isn't known yet.
    public init?(_ playback: LocalPlayback) {
        switch playback.route {
        case .file:
            // A file's own tags say the most; what the player found fills in the rest.
            guard let format = AudioFormat.settled(actual: playback.actual, original: playback.original) else { return nil }
            self.init(format: format, source: .thisDevice, reason: .file)
        case .downloaded(let requested):
            guard let (format, reason) = Self.settle(via: .download, requested: requested, original: playback.original, actual: playback.actual) else { return nil }
            self.init(format: format, source: .downloaded, reason: reason)
        case .stream(let server, let network, let requested):
            guard let (format, reason) = Self.settle(via: .stream(network), requested: requested, original: playback.original, actual: playback.actual) else { return nil }
            self.init(format: format, source: .streaming(server: server), reason: reason)
        }
    }

    private init(format: AudioFormat, source: Source, reason: Reason) {
        let tier: Tier = format.isHiRes ? .hiResLossless : (format.isLossless ? .lossless : .compressed)
        self.init(tier: tier, format: format, source: source, reason: reason)
    }

    /// What arrived when a server was asked for the original or for a smaller copy, and why.
    private static func settle(via: Via, requested: Int?, original: AudioFormat?, actual: AudioFormat?) -> (AudioFormat, Reason)? {
        guard let requested else {
            guard let format = AudioFormat.settled(actual: actual, original: original) else { return nil }
            return (format, .original(via))
        }
        // Asked for a smaller copy: until the audio has been heard, it could be either.
        guard let actual else { return nil }
        let isConverted: Bool = {
            guard let original else {
                // Nothing to compare with: the server's copies are MP3.
                return actual.codec.uppercased() == "MP3"
            }
            if actual.codec.uppercased() != original.codec.uppercased() { return true }
            // Same codec: a lossy file made smaller keeps its codec but not its bit rate.
            guard !original.isLossless, let originalRate = original.bitRate, originalRate > requested else { return false }
            return (actual.bitRate ?? requested) < originalRate
        }()
        if isConverted {
            let rate = Self.bitRate(heard: actual.bitRate, asked: requested)
            return (AudioFormat(codec: actual.codec, sampleRate: actual.sampleRate, bitRate: rate), .converted(via, bitRate: requested))
        }
        let format = AudioFormat.settled(actual: actual, original: original) ?? actual
        if !format.isLossless, let rate = format.bitRate, rate <= requested {
            return (format, .alreadySmaller(via, bitRate: requested))
        }
        return (format, .serverSentOriginal(via, bitRate: requested))
    }

    /// The copy's bit rate: the one asked for, unless what was heard is clearly lower (a
    /// server that won't make a copy bigger than its source).
    private static func bitRate(heard: Int?, asked: Int) -> Int {
        guard let heard, heard > 0, Double(heard) < Double(asked) * 0.9 else { return asked }
        return heard
    }

    // MARK: - Words

    /// Whether the badge wears the waveform, as Music's Lossless does.
    public var showsWaveform: Bool { tier == .lossless || tier == .hiResLossless }

    /// The badge: "Lossless", "Dolby Atmos", "AAC", "MP3 · 320 kbps".
    public var label: String {
        switch tier {
        case .hiResLossless: String(localized: "Hi-Res Lossless")
        case .lossless: String(localized: "Lossless")
        case .dolbyAtmos: String(localized: "Dolby Atmos")
        case .dolbyAudio: String(localized: "Dolby Audio")
        case .spatialAudio: String(localized: "Spatial Audio")
        case .compressed:
            if let format {
                [format.codec, format.detail].compactMap(\.self).joined(separator: " · ")
            } else {
                String(localized: "AAC")
            }
        }
    }

    /// The badge as VoiceOver reads it: "MP3, 320 kilobits a second".
    public var spokenLabel: String {
        guard tier == .compressed, let format, let rate = format.bitRate, rate > 0 else { return label }
        return String(localized: "\(format.codec), \(rate) kilobits a second")
    }

    /// The format in full, for a lossless song: "FLAC 24-bit/96 kHz", "ALAC up to 24-bit/48 kHz".
    /// Nil where the badge already says it all.
    public var formatDetail: String? {
        switch (tier, format) {
        case (.lossless, nil): String(localized: "ALAC up to 24-bit/48 kHz")
        case (.hiResLossless, nil): String(localized: "ALAC up to 24-bit/192 kHz")
        case (.lossless, let format?), (.hiResLossless, let format?):
            [format.codec, format.detail].compactMap(\.self).joined(separator: " ")
        default: nil
        }
    }

    /// Where it's coming from: "Streaming from Octo", "Downloaded", "On This iPhone".
    public var sourceLine: String {
        switch source {
        case .appleMusic: String(localized: "Apple Music")
        case .thisDevice:
            #if os(macOS)
            String(localized: "On This Mac")
            #else
            String(localized: "On This iPhone")
            #endif
        case .downloaded: String(localized: "Downloaded")
        case .streaming(let server): String(localized: "Streaming from \(server)")
        }
    }

    /// Where it's from and the format in full, joined: "Streaming from Octo · FLAC 16-bit/44.1 kHz".
    public var factsLine: String {
        [sourceLine, formatDetail].compactMap(\.self).joined(separator: " · ")
    }

    /// Why it's playing at this quality, in one sentence.
    public var reasonLine: String {
        switch reason {
        case .appleMusic:
            #if os(macOS)
            String(localized: "Apple Music plays at the quality chosen in Music ▸ Settings ▸ Playback.")
            #else
            String(localized: "Apple Music plays at the quality chosen in Settings ▸ Apps ▸ Music ▸ Audio Quality.")
            #endif
        case .file:
            #if os(macOS)
            String(localized: "Songs on this Mac play as they are.")
            #else
            String(localized: "Songs on this iPhone play as they are.")
            #endif
        case .original(.download):
            String(localized: "Downloaded as the original file.")
        case .original(.stream(let network)):
            switch network {
            case .wifi: String(localized: "Your Wi-Fi setting streams the original file.")
            case .cellular: String(localized: "Your cellular setting streams the original file.")
            case .any: String(localized: "Your streaming setting plays the original file.")
            }
        case .converted(.download, let rate):
            String(localized: "Downloaded at \(Self.kbps(rate)), as your Download Quality setting asked.")
        case .converted(.stream(let network), let rate):
            switch network {
            case .wifi: String(localized: "Your Wi-Fi setting streams at \(Self.kbps(rate)).")
            case .cellular: String(localized: "Your cellular setting streams at \(Self.kbps(rate)).")
            case .any: String(localized: "Your streaming setting plays at \(Self.kbps(rate)).")
            }
        case .alreadySmaller(.download, let rate):
            String(localized: "It’s already \(Self.kbps(rate)) or less, so it was downloaded as it is.")
        case .alreadySmaller(.stream, let rate):
            String(localized: "It’s already \(Self.kbps(rate)) or less, so it streams as it is.")
        case .serverSentOriginal(.download, let rate):
            String(localized: "Your server sent the original file instead of a \(Self.kbps(rate)) copy.")
        case .serverSentOriginal(.stream(let network), let rate):
            switch network {
            case .wifi: String(localized: "Your Wi-Fi setting asks for \(Self.kbps(rate)), but your server sent the original file.")
            case .cellular: String(localized: "Your cellular setting asks for \(Self.kbps(rate)), but your server sent the original file.")
            case .any: String(localized: "Your streaming setting asks for \(Self.kbps(rate)), but your server sent the original file.")
            }
        }
    }

    /// "320 kbps", with no grouping: a bit rate is a label, not a quantity.
    private static func kbps(_ rate: Int) -> String {
        String(rate) + " kbps"
    }
}

extension AudioFormat {
    /// The format as a decoder reports it: Core Audio's format id (a four-character code such
    /// as `fLaC`), the sample rate, the format flags (which carry a lossless file's bit depth),
    /// the bits per channel (PCM's depth) and the data rate in bits a second. Nil for a
    /// format Tracks doesn't name.
    public init?(formatID: UInt32, sampleRate: Double, formatFlags: UInt32 = 0, bitsPerChannel: UInt32 = 0, bitsPerSecond: Double? = nil) {
        let codec: String
        var bitDepth: Int?
        switch Self.fourCC(formatID) {
        case "fLaC":
            codec = "FLAC"
            bitDepth = Self.losslessDepth(formatFlags)
        case "alac":
            codec = "ALAC"
            bitDepth = Self.losslessDepth(formatFlags)
        case "lpcm":
            codec = "WAV"
            bitDepth = bitsPerChannel > 0 ? Int(bitsPerChannel) : nil
        case ".mp3", ".mp2", ".mp1":
            codec = "MP3"
        case "aac ", "aach", "aacp", "aacl", "aace", "aacf", "aacg":
            codec = "AAC"
        case "opus":
            codec = "Opus"
        default:
            return nil
        }
        let rate = sampleRate > 0 ? Int(sampleRate.rounded()) : nil
        var kbps: Int?
        if let bitsPerSecond, bitsPerSecond > 0, !["FLAC", "ALAC", "WAV"].contains(codec) {
            kbps = Int((bitsPerSecond / 1_000).rounded())
        }
        self.init(codec: codec, sampleRate: rate, bitDepth: bitDepth, bitRate: kbps)
    }

    /// What's playing, settled from what the player found and what the song says it is: the
    /// song's own description when they agree on the codec, since tags know more than a
    /// decoder's first look, with the gaps filled in; otherwise what was found.
    public static func settled(actual: AudioFormat?, original: AudioFormat?) -> AudioFormat? {
        guard let actual else { return original }
        guard var original, original.codec.uppercased() == actual.codec.uppercased() else { return actual }
        original.sampleRate = original.sampleRate ?? actual.sampleRate
        original.bitDepth = original.bitDepth ?? actual.bitDepth
        original.bitRate = original.bitRate ?? actual.bitRate
        return original
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Apple Lossless and FLAC keep the source's bit depth in their flags.
    private static func losslessDepth(_ flags: UInt32) -> Int? {
        switch flags {
        case 1: 16
        case 2: 20
        case 3: 24
        case 4: 32
        default: nil
        }
    }
}

import AVFoundation
import Foundation
import MusicKit
import Observation
import ShazamKit
import TracksCore
import os

/// The groove of the song playing (see ``Groove``), for the drawing that moves with music
/// Tracks can't hear.
///
/// Apple Music plays in a process of its own, so Tracks never hears the song itself. Each
/// catalog song has a half-minute preview, though, plain sound anyone may fetch. Tracks
/// fetches it once, listens to it for the song's tempo, its drums, its shape and how loud it
/// is, keeps what it learned, with a sketch of its sound band by band (about fifteen kilobytes),
/// and lets the sound itself go. Nothing about you
/// goes with the request.
///
/// Only while something that moves with the music is showing; never under Low Data Mode or in
/// Low Power Mode, when the drawing breathes slowly instead. Sample songs make no sound, so
/// each gets a groove made up from its name.
///
/// The songs the player hands back often come without their previews, as a station's do
/// without their covers, so a song without one is looked up in the catalog first.
@MainActor
@Observable
final class GrooveStore {
    static let shared = GrooveStore()

    /// The groove of the song with ``key``, once it's known.
    private(set) var groove: Groove?
    private(set) var key: String?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The last track asked about and its key: asked every frame something moves with the
    /// music. By its song too, which a station's entry may learn later.
    @ObservationIgnored private var asked: (track: String, song: MusicItemID?, key: String?)?
    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Tracks", category: "Groove")

    private init() {}

    /// The groove of `track`, if it's the song this has learned.
    func groove(for track: PlayerTrack?) -> Groove? {
        guard let track, let groove else { return nil }
        if asked?.track != track.id || asked?.song != track.song?.id {
            asked = (track.id, track.song?.id, Self.key(for: track))
        }
        return key == asked?.key ? groove : nil
    }

    /// Learns `track`'s groove, if it isn't known yet, and stops learning the last one's.
    func follow(_ track: PlayerTrack?, isDemo: Bool) {
        let key = track.flatMap(Self.key(for:))
        // The same song again: only if the last try came to nothing, such as a dropped connection.
        guard key != self.key || (groove == nil && work == nil) else { return }
        work?.cancel()
        work = nil
        self.key = key
        groove = nil
        // Your own music is heard as it plays; it needs no groove.
        guard let track, let key, track.local == nil else { return }
        if isDemo {
            groove = .sample(seed: key)
            return
        }
        guard let song = track.song else { return }
        let mayDownload = !LowPowerMode.shared.isOn
        work = Task { [weak self] in
            let found = await Self.learn(song, key: key, mayDownload: mayDownload)
            guard !Task.isCancelled, let self, self.key == key else { return }
            self.groove = found
            self.work = nil
        }
    }

    private static func learn(_ song: Song, key: String, mayDownload: Bool) async -> Groove? {
        if let kept = await GrooveFiles.kept(for: key) { return kept }
        guard mayDownload else { return nil }
        guard let preview = await previewURL(of: song) else {
            log.notice("No preview for \(song.id.rawValue, privacy: .public)")
            return nil
        }
        do {
            let groove = try await GrooveFiles.learn(key: key, preview: preview, song: SongMatch(song))
            log.notice("\(song.id.rawValue, privacy: .public): \(groove.tempo, format: .fixed(precision: 2)) BPM, sure \(groove.confidence, format: .fixed(precision: 2)), \(groove.loudness ?? 0, format: .fixed(precision: 1)) LUFS, preview at \(groove.songOffset ?? -1, format: .fixed(precision: 2)) s")
            return groove
        } catch {
            if !(error is CancellationError) {
                log.error("Couldn't hear the preview of \(song.id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    /// The song's preview, from the catalog when the player's copy of the song has none: by
    /// its id for a catalog song, by its recording's code for one from your library.
    private static func previewURL(of song: Song) async -> URL? {
        if let url = song.previewAssets?.first?.url { return url }
        do {
            let found: Song?
            if song.id.rawValue.allSatisfy(\.isNumber) {
                found = try await MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: song.id).response().items.first
            } else if let isrc = song.isrc {
                found = try await MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc).response().items.first
            } else {
                found = nil
            }
            return found?.previewAssets?.first?.url
        } catch {
            log.error("Couldn't look up \(song.id.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A catalog song by its id, and a sample song by its name.
    private static func key(for track: PlayerTrack) -> String? {
        if let song = track.song { return song.id.rawValue }
        return track.local == nil ? "sample.\(track.songIdentity)" : nil
    }
}

/// Fetching, hearing and keeping grooves, away from the main thread.
private nonisolated enum GrooveFiles {
    /// Kept in Caches, where the system may clear them; one is soon learned again. Named for
    /// the analysis that learned them, so a better one doesn't play back the old one's mistakes.
    static let folder = URL.cachesDirectory.appending(path: "Grooves 5", directoryHint: .isDirectory)
    static let older = ["Grooves", "Grooves 2", "Grooves 3", "Grooves 4"].map { URL.cachesDirectory.appending(path: $0, directoryHint: .isDirectory) }
    /// About six megabytes at most, each keeping its preview's sound.
    static let kept = 400

    /// Not under Low Data Mode. On cellular, yes: a preview is half a megabyte, a tenth of the
    /// song streaming beside it.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    @concurrent
    static func kept(for key: String) async -> Groove? {
        for old in older where FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.removeItem(at: old)
        }
        let file = file(for: key)
        guard let data = try? Data(contentsOf: file), let groove = try? JSONDecoder().decode(Groove.self, from: data) else { return nil }
        // Marked as used, so it's among the last let go.
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
        return groove
    }

    @concurrent
    static func learn(key: String, preview: URL, song: SongMatch) async throws -> Groove {
        let heard = try await hear(preview)
        try Task.checkCancellation()
        var groove = GrooveAnalysis.groove(of: heard.samples, sampleRate: heard.rate, bandCount: AudioLevelMeter.bandCount)
        groove.songOffset = await PreviewLocator.offset(of: heard.samples, rate: heard.rate, in: song)
        try Task.checkCancellation()
        keep(groove, at: file(for: key))
        return groove
    }

    private static func file(for key: String) -> URL {
        folder.appending(path: "\(fileName(for: key)).json")
    }

    /// The preview's sound, its channels mixed to one.
    private static func hear(_ preview: URL) async throws -> (samples: [Float], rate: Double) {
        let (download, response) = try await session.download(from: preview)
        // AVAudioFile goes by the name's extension to know what it's reading.
        let local = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        defer {
            try? FileManager.default.removeItem(at: download)
            try? FileManager.default.removeItem(at: local)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.moveItem(at: download, to: local)
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: local)
        let format = file.processingFormat
        // A preview is half a minute; anything longer isn't one.
        let length = AVAudioFrameCount(min(file.length, Int64(format.sampleRate * 40)))
        guard length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else { throw URLError(.cannotDecodeContentData) }
        try file.read(into: buffer, frameCount: length)
        guard let channels = buffer.floatChannelData else { throw URLError(.cannotDecodeContentData) }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        // Reading always gives one buffer a channel.
        var mono = [Float](repeating: 0, count: count)
        let share = 1 / Float(max(1, channelCount))
        for channel in 0..<channelCount {
            let data = channels[channel]
            for frame in 0..<count { mono[frame] += data[frame] * share }
        }
        return (mono, format.sampleRate)
    }

    private static func keep(_ groove: Groove, at file: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(groove) else { return }
        try? data.write(to: file, options: .atomic)
        // The least lately used go first, once there are too many.
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys), files.count > kept else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
        for (old, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - kept) {
            try? manager.removeItem(at: old)
        }
    }

    /// A key as a file name: letters, digits and dots only.
    private static func fileName(for key: String) -> String {
        String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." ? Character($0) : "_" })
    }
}

/// What identifies a song, to be sure a match is the same recording.
nonisolated struct SongMatch: Sendable {
    let catalogID: String?
    let isrc: String?

    init(_ song: Song) {
        catalogID = song.id.rawValue.allSatisfy(\.isNumber) ? song.id.rawValue : nil
        isrc = song.isrc
    }

    func accepts(_ item: SHMatchedMediaItem) -> Bool {
        if let catalogID, let found = item.appleMusicID { return found == catalogID }
        if let isrc, let found = item.isrc { return found.caseInsensitiveCompare(isrc) == .orderedSame }
        return catalogID == nil && isrc == nil
    }
}

/// Finds where a preview sits in its song, so the drawing keeps the song's own beat rather
/// than guessing where its first bar falls.
///
/// A preview is a stretch from somewhere in the song, and nothing says where. Shazam knows:
/// asked about a few seconds of the preview, it names the recording and how far into it they
/// are, to a fraction of a second. Only the preview's sound is sent, never anything heard
/// around you. Nil when Shazam can't say, or names another recording.
private nonisolated enum PreviewLocator {
    /// From this far into the preview, past its fade in, for this long.
    static let from = 6.0
    static let length = 10.0

    static func offset(of samples: [Float], rate: Double, in song: SongMatch) async -> Double? {
        let first = Int(from * rate), count = Int(length * rate)
        guard samples.count >= first + count,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress! + first, count: count)
        }
        let generator = SHSignatureGenerator()
        do {
            try generator.append(buffer, at: nil)
        } catch {
            GrooveStore.log.notice("Couldn't sign the preview: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let result = await SHSession().result(from: generator.signature())
        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first(where: song.accepts) else { return nil }
            let offset = item.matchOffset - from
            return offset.isFinite && offset >= 0 ? offset : nil
        case .noMatch:
            return nil
        case .error(let error, _):
            GrooveStore.log.notice("Shazam couldn't place the preview: \(error.localizedDescription, privacy: .public)")
            return nil
        @unknown default:
            return nil
        }
    }
}

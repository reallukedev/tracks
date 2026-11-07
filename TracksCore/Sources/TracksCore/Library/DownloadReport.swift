import Foundation

/// A song downloaded to this iPhone: which song, how much room it takes, and since when.
public struct DownloadedSong: Sendable, Hashable, Identifiable {
    public let track: LocalTrack
    public let bytes: Int64
    public let downloadedAt: Date

    public var id: String { track.id }

    public init(track: LocalTrack, bytes: Int64, downloadedAt: Date) {
        self.track = track
        self.bytes = bytes
        self.downloadedAt = downloadedAt
    }
}

/// What's downloaded, told about: how much of what, which you play, and which could go to make
/// room.
public enum DownloadReport {
    public struct Stats: Sendable, Equatable {
        public var songs = 0
        public var albums = 0
        public var artists = 0
        public var bytes: Int64 = 0
        /// Playing time, where songs' lengths are known.
        public var duration: TimeInterval = 0
        /// The share that's lossless, from 0 to 1.
        public var losslessShare = 0.0
        /// Downloaded and never played.
        public var neverPlayed = 0
    }

    /// Ways to order what's downloaded.
    public enum Order: String, CaseIterable, Sendable, Identifiable {
        case recent, title, artist, size, leastPlayed

        public var id: String { rawValue }
    }

    public static func stats(_ songs: [DownloadedSong], facts: [String: SongFacts]) -> Stats {
        guard !songs.isEmpty else { return Stats() }
        let tracks = songs.map(\.track)
        return Stats(
            songs: songs.count,
            albums: Set(tracks.map(\.albumKey)).count,
            artists: Set(tracks.map(\.artistKey)).count,
            bytes: songs.map(\.bytes).reduce(0, +),
            duration: tracks.compactMap(\.duration).reduce(0, +),
            losslessShare: Double(tracks.filter { $0.format?.isLossless == true }.count) / Double(tracks.count),
            neverPlayed: tracks.filter { facts[$0.identity] == nil }.count
        )
    }

    /// Songs that could go to make room: not played in `idle`, and downloaded at least that
    /// long ago too, so something only just downloaded isn't offered up before it's had a chance.
    /// Biggest first.
    public static func unplayed(_ songs: [DownloadedSong], facts: [String: SongFacts], idle: TimeInterval = 90 * 24 * 60 * 60, now: Date = .now) -> [DownloadedSong] {
        songs
            .filter { song in
                guard now.timeIntervalSince(song.downloadedAt) >= idle else { return false }
                guard let lastHeard = facts[song.track.identity]?.lastHeard else { return true }
                return now.timeIntervalSince(lastHeard) >= idle
            }
            .sorted { $0.bytes > $1.bytes }
    }

    /// The songs you play most of what's downloaded, most first.
    public static func mostPlayed(_ songs: [DownloadedSong], facts: [String: SongFacts], limit: Int = 5) -> [DownloadedSong] {
        Array(songs
            .filter { (facts[$0.track.identity]?.plays ?? 0) > 0 }
            .sorted { (facts[$0.track.identity]?.plays ?? 0) > (facts[$1.track.identity]?.plays ?? 0) }
            .prefix(limit))
    }

    public static func sorted(_ songs: [DownloadedSong], by order: Order, facts: [String: SongFacts]) -> [DownloadedSong] {
        switch order {
        case .recent:
            songs.sorted { $0.downloadedAt > $1.downloadedAt }
        case .title:
            songs.sorted { $0.track.title.localizedStandardCompare($1.track.title) == .orderedAscending }
        case .artist:
            // By artist, then album, as Finder orders names.
            songs.sorted { lhs, rhs in
                let artist = lhs.track.albumArtistName.localizedStandardCompare(rhs.track.albumArtistName)
                if artist != .orderedSame { return artist == .orderedAscending }
                return (lhs.track.album ?? "").localizedStandardCompare(rhs.track.album ?? "") == .orderedAscending
            }
        case .size:
            songs.sorted { $0.bytes > $1.bytes }
        case .leastPlayed:
            songs.sorted { (facts[$0.track.identity]?.plays ?? 0, $0.track.title) < (facts[$1.track.identity]?.plays ?? 0, $1.track.title) }
        }
    }
}

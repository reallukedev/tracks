import Foundation

/// What the person told Tracks’ player about songs without saying it outright: which ones they
/// skip, and which ones they asked to hear less of.
///
/// Kept on this device only. It steers the Play tab's mixes, never the history or the stats.
public struct ListeningSignals: Codable, Sendable, Equatable {
    /// Skips per song identity, newest last. Only the recent ones matter.
    public private(set) var skips: [String: [Date]] = [:]
    /// Song identities the person asked to hear less of.
    public private(set) var suggestLess: Set<String> = []
    /// Artists the person blocked. Not kept with the rest: they're a setting of their own,
    /// shared between devices, and handed in here so everything that asks what to leave out
    /// leaves them out too.
    public var blocked = BlockedArtists()

    private enum CodingKeys: String, CodingKey {
        case skips, suggestLess
    }

    /// How long a skip counts against a song.
    public static let skipMemory: TimeInterval = 60 * 24 * 60 * 60
    /// Songs remembered, so the file can't grow without end. The ones skipped longest ago go.
    public static let songLimit = 1_000
    /// Recent skips it takes to leave a song out of the mixes.
    public static let skipsToDrop = 2

    public init() {}

    /// Whether leaving a song after `playedFor` seconds counts as skipping it.
    ///
    /// Under thirty seconds, or under a third of a short song. A song that ran to the end is
    /// never a skip, and neither is one whose length isn't known yet.
    public static func isSkip(playedFor: TimeInterval, duration: TimeInterval?) -> Bool {
        guard let duration, duration > 0, playedFor >= 0 else { return false }
        guard playedFor < duration - 1 else { return false }
        return playedFor < min(30, duration / 3)
    }

    public mutating func recordSkip(of song: String, at date: Date = .now) {
        var dates = skips[song, default: []].filter { date.timeIntervalSince($0) < Self.skipMemory }
        dates.append(date)
        skips[song] = dates
        trim(now: date)
    }

    /// The song's recent skips, forgotten after ``skipMemory``.
    public func recentSkips(of song: String, now: Date = .now) -> Int {
        skips[song]?.count { now.timeIntervalSince($0) < Self.skipMemory } ?? 0
    }

    /// Whether mixes should leave the song out.
    public func excludes(_ song: String, now: Date = .now) -> Bool {
        suggestLess.contains(song) || recentSkips(of: song, now: now) >= Self.skipsToDrop
            || blocked.blocks(songIdentity: song)
    }

    public mutating func setSuggestLess(_ song: String, _ isOn: Bool) {
        if isOn { suggestLess.insert(song) } else { suggestLess.remove(song) }
    }

    private mutating func trim(now: Date) {
        skips = skips.compactMapValues { dates in
            let kept = dates.filter { now.timeIntervalSince($0) < Self.skipMemory }
            return kept.isEmpty ? nil : kept
        }
        guard skips.count > Self.songLimit else { return }
        let newest = skips
            .sorted { ($0.value.last ?? .distantPast) > ($1.value.last ?? .distantPast) }
            .prefix(Self.songLimit)
        skips = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }
}

#if DEBUG
import Foundation
import TracksCore

/// Invented credits, samples and Last.fm figures for the sample library, which mustn't reach
/// MusicBrainz or Last.fm. Each song gets its own, and some get none, so every state shows.
/// Debug builds only.
///
/// - `-TracksSongInfoLastFM NO` leaves Last.fm out, as with no account connected.
/// - `-TracksSongInfoOffline YES` answers as if the device were offline.
/// - `-TracksSongInfoDelay 2` holds each answer that many seconds, to see the placeholders.
/// - `-TracksSongInfo top` opens Get Info at launch: `top` for the most played song, `once` for
///   one played once, `new` for one never played, `radio` for a radio song Apple Music can't
///   match, or part of a title.
///
/// The `radio` song gets no invented Apple Music facts, as a radio song often has none.
enum SongInfoSamples {
    /// The song `-TracksSongInfo` asks for, once the history has loaded.
    @MainActor
    static func requested(in history: ListeningHistory) -> SongInfoSubject? {
        guard let wanted = UserDefaults.standard.string(forKey: "TracksSongInfo"), !history.captures.isEmpty else { return nil }
        if wanted == "new" {
            return SongInfoSubject(title: "Lantern Light", artistName: "The Halyards")
        }
        var counts: [String: Int] = [:]
        for capture in history.captures { counts[capture.songIdentity, default: 0] += 1 }
        let chosen: CaptureStat? = switch wanted {
        case "top": counts.max { $0.value < $1.value }.flatMap { top in history.captures.last { $0.songIdentity == top.key } }
        case "once": history.captures.last { counts[$0.songIdentity] == 1 }
        case "radio": history.captures.last { $0.stationName != nil }
        default: history.captures.last { $0.title.localizedCaseInsensitiveContains(wanted) }
        }
        if wanted == "radio", let chosen { uncataloged.insert(chosen.songIdentity) }
        return chosen.map {
            SongInfoSubject(
                title: $0.title,
                artistName: $0.artistName,
                albumTitle: $0.albumTitle,
                cover: .url($0.artworkURL, seed: $0.albumTitle ?? $0.title),
                catalogID: wanted == "radio" ? nil : $0.songID
            )
        }
    }

    /// Songs Apple Music is to know nothing about.
    @MainActor static var uncataloged: Set<String> = []

    static var showsLastFM: Bool {
        UserDefaults.standard.object(forKey: "TracksSongInfoLastFM") as? Bool ?? true
    }

    static func wait() async throws {
        let delay = UserDefaults.standard.double(forKey: "TracksSongInfoDelay")
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if UserDefaults.standard.bool(forKey: "TracksSongInfoOffline") {
            throw URLError(.notConnectedToInternet)
        }
    }

    /// The same number for a song every launch, unlike `hashValue`.
    private static func seed(_ subject: SongInfoSubject) -> Int {
        subject.identity.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }

    private static let people = ["Ada Kestrel", "Milo Arden", "Sana Okafor", "Theo Lindqvist", "June Calloway", "Ravi Mehta", "Odile Brandt", "Cass Navarro"]
    private static let instruments = ["piano", "bass guitar", "drums", "strings", "synthesizer"]

    static func credits(for subject: SongInfoSubject) -> SongCredits? {
        let seed = seed(subject)
        // Some songs MusicBrainz simply doesn't know.
        guard seed % 6 != 0 else { return nil }
        let pick = { (offset: Int) in people[(seed / 3 + offset) % people.count] }
        var sections = [
            CreditSection(kind: .performers, credits: [
                Credit(name: subject.artistName, roles: [CreditRole(.vocals, detail: "lead vocals")]),
                Credit(name: pick(0), roles: [CreditRole(.instrument, detail: instruments[seed % instruments.count])]),
            ]),
            CreditSection(kind: .composition, credits: [
                Credit(name: subject.artistName, roles: [CreditRole(.songwriter)]),
                Credit(name: pick(1), roles: [CreditRole(.songwriter), CreditRole(.arranger)]),
            ]),
            CreditSection(kind: .production, credits: [
                Credit(name: pick(2), roles: [CreditRole(.producer)]),
                Credit(name: pick(3), roles: [CreditRole(.mixing), CreditRole(.recording)]),
                Credit(name: pick(4), roles: [CreditRole(.mastering)]),
            ]),
        ]
        if seed % 4 == 1 {
            sections[0].credits.insert(Credit(name: pick(5), roles: [CreditRole(.featured)]), at: 1)
        }
        let samples = seed % 3 == 0 ? [
            RecordingLink(title: "Lantern Light", artistName: "The Halyards", year: 1974, recordingID: "sample-a-\(seed)"),
        ] : []
        let sampledBy = seed % 4 == 2 ? [
            RecordingLink(title: "Low Tide Loop", artistName: "Marlowe Beats", year: 2021, recordingID: "sample-b-\(seed)"),
            RecordingLink(title: "Harbour Lights (Night Mix)", artistName: "Kiri & the Shoals", year: 2023, recordingID: "sample-c-\(seed)"),
        ] : []
        let mashups = seed % 5 == 3 ? [
            RecordingLink(title: "Shorelines Mashup", artistName: "DJ Petrel", year: 2024, recordingID: "sample-d-\(seed)"),
        ] : []
        return SongCredits(
            sections: sections,
            samples: samples,
            sampledBy: sampledBy,
            mashups: mashups,
            workIDs: seed % 5 == 0 ? [] : ["work-\(seed)"],
            genres: ["Indie Pop"],
            recordingID: "sample-\(seed)"
        )
    }

    static func versions(for subject: SongInfoSubject) -> SongVersions? {
        let seed = seed(subject)
        guard seed % 5 != 0 else { return nil }
        var versions = [
            RecordingLink(title: subject.title, artistName: subject.artistName, year: 2024, detail: "Live, 2024-09-14: Harbour Hall, Bristol", recordingID: "version-a-\(seed)"),
        ]
        if seed % 2 == 0 {
            versions.append(RecordingLink(title: "\(subject.title) (Acoustic)", artistName: subject.artistName, year: 2025, detail: "Acoustic", recordingID: "version-b-\(seed)"))
        }
        let covers = seed % 3 == 2 ? [] : [
            RecordingLink(title: subject.title, artistName: "Marigold Static", year: 2025, recordingID: "cover-a-\(seed)"),
            RecordingLink(title: subject.title, artistName: "Fennel String Quartet", year: 2025, detail: "Instrumental", recordingID: "cover-b-\(seed)"),
        ]
        return SongVersions(versions: versions, covers: covers, key: seed % 4 == 0 ? "A minor" : nil)
    }

    static func lastFM(for subject: SongInfoSubject, history: ListeningHistory) -> LastFMTrackInfo? {
        let seed = seed(subject)
        guard seed % 7 != 0 else { return nil }
        let listeners = 2_000 + (seed % 900) * 1_311
        // Other songs from the sample history, so a similar song opens with plays of its own.
        var seen: Set<String> = [subject.identity]
        let others = history.captures.reversed().filter { seen.insert($0.songIdentity).inserted }
        let similar: [LastFMTrackInfo.SimilarTrack] = others.isEmpty ? [] : (0..<5).map { index in
            let capture = others[(seed / 5 + index * 7) % others.count]
            return LastFMTrackInfo.SimilarTrack(title: capture.title, artistName: capture.artistName)
        }
        return LastFMTrackInfo(
            listeners: listeners,
            scrobbles: listeners * (3 + seed % 9),
            yourScrobbles: 12 + seed % 140,
            tags: Array(["Indie Pop", "Dream Pop", "Chill", "Coastal", "Female Vocalists", "2020s"].dropFirst(seed % 3).prefix(4)),
            summary: seed % 2 == 0
                ? String(localized: "\(subject.title) is a song by \(subject.artistName), written over one winter in a converted boathouse. It became a late-night favourite on independent radio before it was ever released as a single, and is often played to close their shows.")
                : nil,
            url: URL(string: "https://www.last.fm/music"),
            similar: Array(Set(similar)).sorted { $0.title < $1.title }
        )
    }
}
#endif

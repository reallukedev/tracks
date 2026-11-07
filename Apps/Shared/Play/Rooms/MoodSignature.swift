import SwiftUI
import TracksCore

/// The section each mood's page has that no other has, made for what the mood is for and only
/// from what your history can say: when you play a song, how often, on which days and drives.
/// Tracks knows a song's genre and nothing of its tempo, so none of these claim to.
struct MoodSignature {
    let title: String
    /// What's in it and why, under its title.
    let note: String
    /// Numbered, where the order is the point.
    var isSequence = false
    let songs: (ListeningRoom) -> [ListeningRoom.Song]
    /// The fact at each row's trailing edge.
    let detail: (ListeningRoom.Song) -> String?
}

extension Mood {
    var signature: MoodSignature {
        switch self {
        case .chill:
            MoodSignature(
                title: String(localized: "Wind Down"),
                note: String(localized: "Your evening songs, from the liveliest genres to the calmest."),
                isSequence: true,
                songs: { $0.windDown() },
                detail: { $0.genre }
            )
        case .sleep:
            MoodSignature(
                title: String(localized: "After Dark"),
                note: String(localized: "The ones you mostly play after ten at night."),
                songs: { $0.lateNight() },
                detail: { PlayCountText.short($0.plays) }
            )
        case .focus:
            MoodSignature(
                title: String(localized: "Instrumental First"),
                note: String(localized: "Classical, ambient and scores first, then the rest."),
                songs: { $0.instrumentalFirst() },
                detail: { $0.genre }
            )
        case .workout, .party:
            MoodSignature(
                title: String(localized: "On Repeat This Month"),
                note: String(localized: "Your most played in the last 30 days."),
                songs: { $0.thisMonth() },
                detail: { String(localized: "\($0.recentPlays) this month") }
            )
        case .energy:
            MoodSignature(
                title: String(localized: "Morning Lift"),
                note: String(localized: "The ones you mostly play before noon."),
                songs: { $0.mornings() },
                detail: { PlayCountText.short($0.plays) }
            )
        case .feelGood:
            MoodSignature(
                title: String(localized: "Still Feels Good"),
                note: String(localized: "First played over a year ago, and still on lately."),
                songs: { $0.throwbacks() },
                detail: { String(localized: "Since \($0.firstHeard.formatted(.dateTime.year()))") }
            )
        case .love:
            MoodSignature(
                title: String(localized: "Month After Month"),
                note: String(localized: "The ones you keep coming back to."),
                songs: { $0.monthAfterMonth() },
                detail: { String(AttributedString(localized: "^[\($0.months) month](inflect: true)").characters) }
            )
        case .heartbreak:
            MoodSignature(
                title: String(localized: "Over and Over"),
                note: String(localized: "Songs you've played three times or more in one day."),
                songs: { $0.overAndOver() },
                detail: { String(localized: "\($0.bestDay) in a day") }
            )
        case .drive:
            MoodSignature(
                title: String(localized: "Heard on the Road"),
                note: String(localized: "Played on drives Tracks noticed."),
                songs: { $0.onTheRoad() },
                detail: { String(localized: "\($0.drivePlays) on the road") }
            )
        }
    }

    /// A length to play for, where the mood is a session with an end: a sleep timer for Sleep,
    /// a focus session, a workout. Nil for the rest.
    var session: MoodSession? {
        switch self {
        case .sleep: MoodSession(title: "Sleep Timer", symbol: "moon.zzz", minutes: [15, 30, 45, 60], itemTitle: { "Stop in \($0) Minutes" })
        case .focus: MoodSession(title: "Focus Session", symbol: "timer", minutes: [25, 50, 90], itemTitle: { "Focus for \($0) Minutes" })
        case .workout: MoodSession(title: "Workout Length", symbol: "stopwatch", minutes: [20, 30, 45, 60], itemTitle: { "Work Out for \($0) Minutes" })
        default: nil
        }
    }

    /// The facts line under the mood's name: how many of your songs suit it, and when you play
    /// it most where one part of the day stands out.
    func facts(for room: ListeningRoom) -> String? {
        guard !room.isEmpty else { return nil }
        let count = String(AttributedString(localized: "^[\(room.songs.count) song](inflect: true) of yours").characters)
        guard let peak = room.peak else { return count }
        return "\(count) · \(peak.mostlyLine)"
    }
}

/// A length to play a mood for, after which the music stops: the player's own sleep timer.
struct MoodSession {
    let title: LocalizedStringKey
    let symbol: String
    let minutes: [Int]
    let itemTitle: (Int) -> LocalizedStringKey
}

extension DayPart {
    /// "Mostly in the evening", for a facts line.
    var mostlyLine: String {
        switch self {
        case .morning: String(localized: "Mostly in the morning")
        case .afternoon: String(localized: "Mostly in the afternoon")
        case .evening: String(localized: "Mostly in the evening")
        case .night: String(localized: "Mostly at night")
        }
    }
}

extension ListeningRoom.Song {
    var cover: CoverArt { .url(song.artworkURL, seed: song.albumTitle ?? song.title) }
}

extension ListeningRoom {
    /// The covers for a hero, one per album, the most played first.
    func covers(_ count: Int) -> [CoverArt] {
        var seen = Set<String>()
        var covers: [CoverArt] = []
        for song in songs where covers.count < count {
            if seen.insert(song.song.albumTitle.map(StatsCalculator.folded) ?? song.id).inserted {
                covers.append(song.cover)
            }
        }
        return covers
    }
}

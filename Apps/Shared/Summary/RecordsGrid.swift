import SwiftUI
import TracksCore

/// Bests inside the range, as tiles like the ones under the listening card. A record that
/// wasn't set (one artist all month, nothing played twice in a day) leaves no gap.
struct RecordsGrid: View {
    let records: ListeningRecords
    var columns = 3

    var body: some View {
        TileGrid(tiles: tiles, columns: columns, spacing: Metrics.cardSpacing)
    }

    private var tiles: [GlanceTile] {
        var tiles: [GlanceTile] = []
        if let day = records.biggestDay {
            tiles.append(GlanceTile(
                title: "Biggest Day",
                value: Format.listening(day.seconds),
                symbol: "trophy.fill",
                tint: .orange,
                detail: "\(Format.compactDay(day.day)) · ^[\(day.songCount) song](inflect: true)"
            ))
        }
        if let session = records.longestSession {
            tiles.append(GlanceTile(
                title: "Longest Session",
                value: Format.listening(session.seconds),
                symbol: "timer",
                tint: .blue,
                detail: "\(Format.compactDay(session.start)) · ^[\(session.songCount) song](inflect: true)"
            ))
        }
        if let repeated = records.mostRepeated {
            tiles.append(GlanceTile(
                title: "On Repeat",
                value: repeated.count.formatted(),
                symbol: "repeat",
                tint: .pink,
                unit: "^[\(repeated.count) play](inflect: true)",
                detail: "\(repeated.title), \(Format.compactDay(repeated.day))"
            ))
        }
        if let day = records.mostArtistsDay {
            tiles.append(GlanceTile(
                title: "Most Artists",
                value: day.artistCount.formatted(),
                symbol: "person.3.fill",
                tint: .purple,
                unit: "^[\(day.artistCount) artist](inflect: true)",
                detail: "\(Format.compactDay(day.day))"
            ))
        }
        if let latest = records.latestListen {
            tiles.append(GlanceTile(
                title: "Latest Song",
                value: latest.formatted(date: .omitted, time: .shortened),
                symbol: "moon.stars.fill",
                tint: .indigo,
                detail: "\(Format.compactDay(latest))"
            ))
        }
        if let earliest = records.earliestListen {
            tiles.append(GlanceTile(
                title: "Earliest Song",
                value: earliest.formatted(date: .omitted, time: .shortened),
                symbol: "sunrise.fill",
                tint: .teal,
                detail: "\(Format.compactDay(earliest))"
            ))
        }
        return tiles
    }
}

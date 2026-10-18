import Foundation
import TracksCore

extension LiveMix.Reason {
    /// Why the song came up, in a few words, under it in Up Next.
    var line: String {
        switch self {
        case .newFind: String(localized: "New to you")
        case .newFromYourArtist: String(localized: "New to you, by an artist you play")
        case .newFindLike(let artist): String(localized: "New to you, like \(artist)")
        case .onTheRoad: String(localized: "Played on your drives")
        case .aroundNow: String(localized: "Often played around now")
        case .leaningInto(let genre): String(localized: "Leaning into \(genre)")
        case .oldFavorite(let lastHeard): String(localized: "Not played since \(Self.month(lastHeard))")
        case .mostPlayed: String(localized: "One of your most played")
        case .moreOf(let genre): String(localized: "More \(genre), since you let one play")
        case .moreLike(let artist): String(localized: "More like \(artist)")
        case .probing: String(localized: "Trying a few directions to start")
        case .goesWith(let title): String(localized: "Because you played \u{201C}\(title)\u{201D}")
        }
    }

    var symbol: String {
        switch self {
        case .newFind, .newFromYourArtist, .newFindLike: "sparkles"
        case .onTheRoad: "car"
        case .aroundNow: "clock"
        case .leaningInto: "slider.horizontal.3"
        case .oldFavorite: "clock.arrow.circlepath"
        case .mostPlayed: "flame"
        case .moreOf, .moreLike: "scope"
        case .probing: "arrow.triangle.branch"
        case .goesWith: "link"
        }
    }

    /// "March", or "March 2024" for a month in another year.
    private static func month(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.wide).year())
    }
}

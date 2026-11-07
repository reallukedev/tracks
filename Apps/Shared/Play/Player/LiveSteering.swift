import Foundation
import TracksCore

extension LiveMix.Steering {
    /// A turn away after a run of skips, said at once. A turn toward is quieter: Up Next says it.
    var isTurningAway: Bool {
        switch self {
        case .awayFromGenre, .awayFromDecade, .fewerNewFinds, .moreNewFinds, .tryingSomethingElse: true
        case .towardGenre, .towardArtist, .settledOn: false
        }
    }

    /// A few words, for the confirmation shown as it turns.
    var headline: String {
        switch self {
        case .awayFromGenre(let genre): String(localized: "Less \(genre) for Now")
        case .awayFromDecade(let year): String(localized: "Less from the \(Self.decade(year)) for Now")
        case .fewerNewFinds: String(localized: "More Songs You Know")
        case .moreNewFinds: String(localized: "Trying New Finds")
        case .tryingSomethingElse: String(localized: "Trying Something Different")
        case .towardGenre(let genre): String(localized: "More \(genre)")
        case .towardArtist(let artist): String(localized: "More Like \(artist)")
        case .settledOn(let genre): String(localized: "Settled on \(genre)")
        }
    }

    /// What it's doing and why, in a sentence, under Up Next.
    var line: String {
        switch self {
        case .awayFromGenre(let genre):
            String(localized: "You skipped a few \(genre) songs in a row, so it's playing other things for a while.")
        case .awayFromDecade(let year):
            String(localized: "You skipped a few songs from the \(Self.decade(year)) in a row, so it's playing other years for a while.")
        case .fewerNewFinds:
            String(localized: "You skipped a few new finds in a row, so it's playing more songs you know.")
        case .moreNewFinds:
            String(localized: "You skipped a few songs you know in a row, so it's trying more new finds.")
        case .tryingSomethingElse:
            String(localized: "Nothing's landing, so it's trying genres it hasn't played yet. Let one play and it'll follow.")
        case .towardGenre(let genre):
            String(localized: "You let a \(genre) song play, so more like it are coming.")
        case .towardArtist(let artist):
            String(localized: "More like \(artist) are coming.")
        case .settledOn(let genre):
            String(localized: "\(genre) landed best of the first few songs, so more of it is coming, with something different now and then.")
        }
    }

    /// "’80s", or "2010s" for a year in this century, as people say them.
    static func decade(_ year: Int) -> String {
        let decade = year / 10 * 10
        return decade < 2000 ? "\u{2019}\(decade % 100)s" : "\(decade)s"
    }
}

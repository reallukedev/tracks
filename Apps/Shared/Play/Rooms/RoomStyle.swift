import SwiftUI
import TracksCore

/// How a mood's or a genre's page looks and moves, so each is built for what it is: its own
/// two colours, the type its name is set in, how its covers are laid out, and its pace.
struct RoomStyle {
    /// How the hero lays out its covers.
    enum Covers {
        /// A hand of records, fanned: bright, open moods.
        case fan
        /// A loose pile, tilted: laid back.
        case pile
        /// A tight grid, like a crate or a sequencer.
        case grid
        /// A rising row, one after the next: momentum.
        case strip
        /// One cover, alone: quiet, intimate.
        case single
        /// Two covers, leaning together.
        case pair
    }

    /// How much room the page gives each thing, and how much of a list it shows at once.
    enum Pace {
        case calm, steady, bright

        var sectionSpacing: CGFloat {
            #if os(macOS)
            switch self {
            case .calm: 52
            case .steady: 40
            case .bright: 32
            }
            #else
            switch self {
            case .calm: 40
            case .steady: 32
            case .bright: 26
            }
            #endif
        }

        /// Rows shown before Show More. On the Mac they fill columns, so a multiple of three.
        var rows: Int {
            #if os(macOS)
            switch self {
            case .calm: 9
            case .steady, .bright: 12
            }
            #else
            switch self {
            case .calm: 5
            case .steady: 6
            case .bright: 8
            }
            #endif
        }
    }

    /// The name's type: a design, weight and width SF has, italic or not, and its tracking.
    struct Title {
        var design: Font.Design = .default
        var weight: Font.Weight = .bold
        var width: Font.Width = .standard
        var isItalic = false
        var tracking: CGFloat = 0

        func font(size: CGFloat) -> Font {
            let font = Font.system(size: size, weight: weight, design: design).width(width)
            return isItalic ? font.italic() : font
        }
    }

    let base: Color
    /// The second colour its field leans into.
    let partner: Color
    let symbol: String
    let title: Title
    let covers: Covers
    let pace: Pace

    /// The field's colours, deep enough everywhere that white type reads on them.
    var field: [Color] {
        let deep = base.mix(with: .black, by: 0.32)
        return [
            partner.mix(with: base, by: 0.25), base, base.mix(with: partner, by: 0.3),
            base, base.mix(with: partner, by: 0.45), deep,
            deep, base.mix(with: .black, by: 0.4), partner.mix(with: .black, by: 0.42),
        ]
    }

    /// Text and small glyphs in the room's colour on the page, readable in light and dark.
    var ink: LegibleInk { .ink(base) }
}

// MARK: - Moods

extension Mood {
    /// What its page is built from.
    var style: RoomStyle {
        switch self {
        case .feelGood:
            RoomStyle(base: base, partner: Color(red: 1, green: 0.72, blue: 0.12), symbol: symbol,
                      title: .init(design: .rounded, weight: .heavy), covers: .fan, pace: .bright)
        case .energy:
            RoomStyle(base: base, partner: Color(red: 0.93, green: 0.13, blue: 0.4), symbol: symbol,
                      title: .init(weight: .black, width: .compressed, isItalic: true), covers: .strip, pace: .bright)
        case .workout:
            RoomStyle(base: base, partner: Color(red: 0.98, green: 0.42, blue: 0.08), symbol: symbol,
                      title: .init(weight: .black, width: .expanded, isItalic: true), covers: .strip, pace: .bright)
        case .focus:
            RoomStyle(base: base, partner: Color(red: 0.2, green: 0.27, blue: 0.42), symbol: symbol,
                      title: .init(weight: .light, tracking: 1.5), covers: .grid, pace: .calm)
        case .chill:
            RoomStyle(base: base, partner: Color(red: 0.16, green: 0.42, blue: 0.72), symbol: symbol,
                      title: .init(design: .rounded, weight: .medium), covers: .pile, pace: .calm)
        case .love:
            RoomStyle(base: base, partner: Color(red: 0.74, green: 0.08, blue: 0.2), symbol: symbol,
                      title: .init(design: .serif, weight: .semibold, isItalic: true), covers: .pair, pace: .steady)
        case .drive:
            RoomStyle(base: base, partner: Color(red: 0.93, green: 0.45, blue: 0.22), symbol: symbol,
                      title: .init(weight: .bold, width: .expanded), covers: .strip, pace: .steady)
        case .heartbreak:
            RoomStyle(base: base, partner: Color(red: 0.62, green: 0.3, blue: 0.48), symbol: symbol,
                      title: .init(design: .serif, weight: .regular, isItalic: true), covers: .single, pace: .calm)
        case .party:
            RoomStyle(base: base, partner: Color(red: 0.42, green: 0.2, blue: 0.9), symbol: symbol,
                      title: .init(weight: .black, width: .expanded), covers: .grid, pace: .bright)
        case .sleep:
            RoomStyle(base: base, partner: Color(red: 0.32, green: 0.22, blue: 0.56), symbol: symbol,
                      title: .init(design: .rounded, weight: .light, tracking: 0.5), covers: .single, pace: .calm)
        }
    }
}

// MARK: - Genres

extension MusicGenre {
    /// What its page is built from: its name set as its music sounds, from the era and the
    /// instruments it's known for.
    var style: RoomStyle {
        let (partner, title, covers, pace): (Color, RoomStyle.Title, RoomStyle.Covers, RoomStyle.Pace) = switch id {
        case "pop": (Color(red: 1, green: 0.48, blue: 0.42), .init(design: .rounded, weight: .heavy), .fan, .bright)
        case "hip-hop": (Color(red: 0.16, green: 0.12, blue: 0.1), .init(weight: .black, width: .compressed), .grid, .bright)
        case "r-b": (Color(red: 0.84, green: 0.34, blue: 0.46), .init(design: .serif, weight: .medium, isItalic: true), .pile, .steady)
        case "rock": (Color(red: 0.16, green: 0.12, blue: 0.12), .init(weight: .heavy, width: .condensed), .pile, .bright)
        case "alternative": (Color(red: 0.5, green: 0.55, blue: 0.18), .init(weight: .semibold, width: .condensed), .pile, .steady)
        case "electronic": (Color(red: 0.52, green: 0.18, blue: 0.92), .init(design: .monospaced, weight: .bold), .grid, .bright)
        case "country": (Color(red: 0.86, green: 0.56, blue: 0.22), .init(design: .serif, weight: .heavy), .single, .steady)
        case "latin": (Color(red: 0.95, green: 0.68, blue: 0.1), .init(weight: .heavy, width: .expanded), .fan, .bright)
        case "k-pop": (Color(red: 0.95, green: 0.4, blue: 0.7), .init(design: .rounded, weight: .black), .fan, .bright)
        case "metal": (Color(red: 0.55, green: 0.07, blue: 0.07), .init(weight: .black, width: .compressed), .grid, .bright)
        case "jazz": (Color(red: 0.72, green: 0.52, blue: 0.18), .init(design: .serif, weight: .bold, isItalic: true), .pile, .calm)
        case "singer-songwriter": (Color(red: 0.62, green: 0.46, blue: 0.3), .init(design: .serif, weight: .regular), .single, .calm)
        case "classical": (Color(red: 0.66, green: 0.5, blue: 0.22), .init(design: .serif, weight: .regular, tracking: 2), .single, .calm)
        case "afrobeats": (Color(red: 0.92, green: 0.62, blue: 0.08), .init(weight: .black, width: .expanded), .fan, .bright)
        case "reggae": (Color(red: 0.08, green: 0.48, blue: 0.24), .init(design: .rounded, weight: .bold), .fan, .steady)
        case "blues": (Color(red: 0.14, green: 0.15, blue: 0.32), .init(design: .serif, weight: .regular, isItalic: true), .single, .calm)
        case "soundtrack": (Color(red: 0.6, green: 0.46, blue: 0.24), .init(weight: .light, width: .expanded, tracking: 2), .strip, .steady)
        case "christian": (Color(red: 0.92, green: 0.74, blue: 0.45), .init(design: .serif, weight: .light), .single, .calm)
        default: (color.mix(with: .black, by: 0.4), .init(), .fan, .steady)
        }
        return RoomStyle(base: color, partner: partner, symbol: symbol, title: title, covers: covers, pace: pace)
    }

    /// One line on what the genre is, under its name.
    var tagline: String {
        switch id {
        case "pop": String(localized: "Big hooks, bright choruses.")
        case "hip-hop": String(localized: "Beats, bars and the stories in them.")
        case "r-b": String(localized: "Smooth, soulful and close.")
        case "rock": String(localized: "Guitars up, drums loud.")
        case "alternative": String(localized: "Off the main road, on purpose.")
        case "electronic": String(localized: "Synths, drum machines and the dance floor.")
        case "country": String(localized: "Steel guitar and a story.")
        case "latin": String(localized: "Rhythm from every corner of Latin music.")
        case "k-pop": String(localized: "Polished, bold and built for the stage.")
        case "metal": String(localized: "Heavy riffs, nothing held back.")
        case "jazz": String(localized: "Horns, keys and room to breathe.")
        case "singer-songwriter": String(localized: "One voice, one guitar, the words up front.")
        case "classical": String(localized: "Orchestras, soloists and centuries of scores.")
        case "afrobeats": String(localized: "Grooves from Lagos to the world.")
        case "reggae": String(localized: "Offbeat, easy and rooted.")
        case "blues": String(localized: "Twelve bars and a feeling.")
        case "soundtrack": String(localized: "Scores and songs from the screen.")
        case "christian": String(localized: "Songs of faith and praise.")
        default: String(localized: "What you play most, and what everyone's playing.")
        }
    }
}

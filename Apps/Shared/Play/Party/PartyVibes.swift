import SwiftUI
import TracksCore

extension PartyVibe {
    /// Where the page keeps the party last chosen.
    static let storageKey = "partyVibe"

    var title: String {
        switch self {
        case .danceFloor: String(localized: "Dance Floor")
        case .houseParty: String(localized: "House Party")
        case .pregame: String(localized: "Pregame")
        case .dinnerParty: String(localized: "Dinner Party")
        case .backyard: String(localized: "Backyard")
        case .throwback: String(localized: "Throwback")
        case .hipHop: String(localized: "Hip-Hop")
        case .latinNight: String(localized: "Latin Night")
        case .allAges: String(localized: "All Ages")
        }
    }

    /// One line on the party, under the page's name.
    var tagline: String {
        switch self {
        case .danceFloor: String(localized: "Big songs to keep everyone dancing.")
        case .houseParty: String(localized: "Something for everyone, all night long.")
        case .pregame: String(localized: "Loud, fast songs to get the night going.")
        case .dinnerParty: String(localized: "Warm, easy music under good conversation.")
        case .backyard: String(localized: "Sunny songs for the grill and the lawn.")
        case .throwback: String(localized: "The songs everyone knows every word to.")
        case .hipHop: String(localized: "Hip-hop and rap to turn the room up.")
        case .latinNight: String(localized: "Reggaeton, salsa and bachata till late.")
        case .allAges: String(localized: "Clean, happy songs for every age.")
        }
    }

    var symbol: String {
        switch self {
        case .danceFloor: "figure.dance"
        case .houseParty: "music.note.house.fill"
        case .pregame: "flame.fill"
        case .dinnerParty: "wineglass.fill"
        case .backyard: "sun.max.fill"
        case .throwback: "opticaldisc.fill"
        case .hipHop: "music.mic"
        case .latinNight: "figure.socialdance"
        case .allAges: "figure.2.and.child.holdinghands"
        }
    }

    /// What Your Party Mix is made of, honestly: it goes by genre, and Throwback by year too.
    var mixLine: String {
        switch self {
        case .danceFloor: String(localized: "Your most-played dance, house and pop.")
        case .houseParty: String(localized: "Your most-played pop, hip-hop and dance.")
        case .pregame: String(localized: "Your most-played hip-hop, EDM and house.")
        case .dinnerParty: String(localized: "Your most-played jazz, soul and R&B.")
        case .backyard: String(localized: "Your most-played reggae, country, funk and soul.")
        case .throwback: String(localized: "Your most-played songs from ten or more years ago.")
        case .hipHop: String(localized: "Your most-played hip-hop, rap and R&B.")
        case .latinNight: String(localized: "Your most-played Latin, reggaeton and salsa.")
        case .allAges: String(localized: "Your most-played pop, soundtracks and kids' music.")
        }
    }

    /// The name Your Party Mix is saved under.
    var playlistName: String {
        switch self {
        case .danceFloor: String(localized: "Dance Floor Party")
        case .houseParty: String(localized: "House Party")
        case .pregame: String(localized: "Pregame")
        case .dinnerParty: String(localized: "Dinner Party")
        case .backyard: String(localized: "Backyard Party")
        case .throwback: String(localized: "Throwback Party")
        case .hipHop: String(localized: "Hip-Hop Party")
        case .latinNight: String(localized: "Latin Night")
        case .allAges: String(localized: "All Ages Party")
        }
    }

    /// The party's deepest colour, for type and tints over white.
    var color: Color { palette[0] }

    /// Three colours for the party's field, deep to light, the first two dark enough for white
    /// type. Dance Floor wears the Party mood's own, so the tile opens onto the colour it showed.
    var palette: [Color] {
        switch self {
        case .danceFloor: [Color(red: 0.46, green: 0.06, blue: 0.56), Color(red: 0.8, green: 0.14, blue: 0.62), Color(red: 0.98, green: 0.4, blue: 0.5)]
        case .houseParty: [Color(red: 0.14, green: 0.1, blue: 0.46), Color(red: 0.32, green: 0.26, blue: 0.8), Color(red: 0.56, green: 0.5, blue: 0.96)]
        case .pregame: [Color(red: 0.02, green: 0.18, blue: 0.38), Color(red: 0.04, green: 0.42, blue: 0.72), Color(red: 0.1, green: 0.78, blue: 0.86)]
        case .dinnerParty: [Color(red: 0.34, green: 0.04, blue: 0.12), Color(red: 0.58, green: 0.1, blue: 0.22), Color(red: 0.86, green: 0.58, blue: 0.34)]
        case .backyard: [Color(red: 0.04, green: 0.3, blue: 0.18), Color(red: 0.12, green: 0.48, blue: 0.24), Color(red: 0.94, green: 0.76, blue: 0.24)]
        case .throwback: [Color(red: 0.06, green: 0.24, blue: 0.32), Color(red: 0.78, green: 0.32, blue: 0.1), Color(red: 0.98, green: 0.68, blue: 0.22)]
        case .hipHop: [Color(red: 0.08, green: 0.07, blue: 0.12), Color(red: 0.36, green: 0.14, blue: 0.44), Color(red: 0.92, green: 0.64, blue: 0.16)]
        case .latinNight: [Color(red: 0.58, green: 0.04, blue: 0.16), Color(red: 0.86, green: 0.2, blue: 0.18), Color(red: 1, green: 0.66, blue: 0.18)]
        case .allAges: [Color(red: 0.02, green: 0.3, blue: 0.46), Color(red: 0.06, green: 0.46, blue: 0.58), Color(red: 0.98, green: 0.8, blue: 0.3)]
        }
    }

    /// The parties in the order the chips show them. With explicit songs off, All Ages leads:
    /// it's the one that favours clean playlists.
    static func ordered(allowsExplicit: Bool) -> [PartyVibe] {
        allowsExplicit ? allCases : [.allAges] + allCases.filter { $0 != .allAges }
    }
}

/// The party's colour, lit a little from the top, as a mood's field is.
struct PartyField: View {
    let vibe: PartyVibe

    var body: some View {
        HueField(color: vibe.palette[1])
    }
}

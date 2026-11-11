import AppIntents
import TracksCore

/// What Siri and Shortcuts can start in Tracks by name.
///
/// A file of its own, with no app types, because the widget extension compiles it too: the
/// Play in Tracks control offers the same choices.
enum PlayChoice: String, AppEnum {
    case station
    case forYou
    case discover
    case onRepeat
    case favorites
    case deepCuts
    case radioFinds
    case radio
    case feelGood, energy, workout, focus, chill, love, drive, party, sleep, heartbreak

    /// The mood this choice is, if it's one.
    var mood: Mood? {
        switch self {
        case .feelGood: .feelGood
        case .energy: .energy
        case .workout: .workout
        case .focus: .focus
        case .chill: .chill
        case .love: .love
        case .drive: .drive
        case .heartbreak: .heartbreak
        case .party: .party
        case .sleep: .sleep
        default: nil
        }
    }

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music"

    // A literal, as App Intents reads it at build time. Keep the symbols in step with
    // `symbolName`, which controls need as a plain name.
    static let caseDisplayRepresentations: [PlayChoice: DisplayRepresentation] = [
        .station: DisplayRepresentation(title: "Tracks Radio", subtitle: "Your station, picked as it plays", image: .init(systemName: "dot.radiowaves.left.and.right")),
        .forYou: DisplayRepresentation(title: "My Mix", subtitle: "What you play at this time of day", image: .init(systemName: "sun.max")),
        .discover: DisplayRepresentation(title: "Discover", subtitle: "Songs you haven't heard by artists you love", image: .init(systemName: "binoculars")),
        .onRepeat: DisplayRepresentation(title: "On Repeat", image: .init(systemName: "repeat")),
        .favorites: DisplayRepresentation(title: "All-Time Favorites", image: .init(systemName: "heart")),
        .deepCuts: DisplayRepresentation(title: "Deep Cuts", image: .init(systemName: "square.stack.3d.down.right")),
        .radioFinds: DisplayRepresentation(title: "Radio Finds", image: .init(systemName: "dot.radiowaves.left.and.right")),
        .radio: DisplayRepresentation(title: "The Radio", subtitle: "Apple Music 1, live", image: .init(systemName: "antenna.radiowaves.left.and.right")),
        .feelGood: DisplayRepresentation(title: "Feel Good", image: .init(systemName: "sun.max.fill")),
        .energy: DisplayRepresentation(title: "Energy", image: .init(systemName: "bolt.fill")),
        .workout: DisplayRepresentation(title: "Workout", image: .init(systemName: "figure.run")),
        .focus: DisplayRepresentation(title: "Focus", image: .init(systemName: "scope")),
        .chill: DisplayRepresentation(title: "Chill", image: .init(systemName: "leaf.fill")),
        .love: DisplayRepresentation(title: "Love Songs", image: .init(systemName: "heart.fill")),
        .drive: DisplayRepresentation(title: "Drive", image: .init(systemName: "car.fill")),
        .heartbreak: DisplayRepresentation(title: "Heartbreak", image: .init(systemName: "heart.slash.fill")),
        .party: DisplayRepresentation(title: "Party", image: .init(systemName: "party.popper.fill")),
        .sleep: DisplayRepresentation(title: "Sleep", image: .init(systemName: "moon.stars.fill")),
    ]

    /// The title, for a control's label.
    var title: LocalizedStringResource {
        Self.caseDisplayRepresentations[self]?.title ?? "Tracks Radio"
    }

    var symbolName: String {
        switch self {
        case .station, .radioFinds: "dot.radiowaves.left.and.right"
        case .forYou: "sun.max"
        case .discover: "binoculars"
        case .onRepeat: "repeat"
        case .favorites: "heart"
        case .deepCuts: "square.stack.3d.down.right"
        case .radio: "antenna.radiowaves.left.and.right"
        case .feelGood: "sun.max.fill"
        case .energy: "bolt.fill"
        case .workout: "figure.run"
        case .focus: "scope"
        case .chill: "leaf.fill"
        case .love: "heart.fill"
        case .drive: "car.fill"
        case .heartbreak: "heart.slash.fill"
        case .party: "party.popper.fill"
        case .sleep: "moon.stars.fill"
        }
    }
}

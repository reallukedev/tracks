import SwiftUI

/// How Stage lays out the song.
enum StageLayout: String, CaseIterable, Identifiable {
    /// The cover large beside the song's name, as on a record sleeve.
    case cover
    /// The song's name set huge over the background, as on a gig poster.
    case poster
    /// The visualizer at the centre, the song's name small beneath it.
    case visualizer
    /// The time, large, with the song under it: for a nightstand or a desk.
    case clock

    var id: String { rawValue }
    static let storageKey = "stageLayout"

    var title: LocalizedStringKey {
        switch self {
        case .cover: "Cover"
        case .poster: "Poster"
        case .visualizer: "Visualizer"
        case .clock: "Clock"
        }
    }

    var symbol: String {
        switch self {
        case .cover: "square.and.line.vertical.and.square"
        case .poster: "textformat.size.larger"
        case .visualizer: "waveform"
        case .clock: "clock"
        }
    }
}

/// How the visualizer draws the sound.
enum StageVisualizer: String, CaseIterable, Identifiable {
    /// The music from low notes to high, each band a bar that springs with it.
    case bars
    /// The cover's colours as a soft cloud that swells with the music.
    case glow
    /// Light blooming from behind the cover on each beat.
    case halo
    /// The last few seconds passing by, as Voice Memos draws a recording.
    case waveform
    case off

    var id: String { rawValue }
    static let storageKey = "stageVisualizer"

    /// The styles these took the place of, as the nearest of them, so a choice made before
    /// carries on.
    init?(rawValue: String) {
        switch rawValue {
        case "bars": self = .bars
        case "glow": self = .glow
        case "halo", "orb": self = .halo
        case "waveform", "wave": self = .waveform
        case "off": self = .off
        default: return nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .bars: "Bars"
        case .glow: "Glow"
        case .halo: "Halo"
        case .waveform: "Waveform"
        case .off: "Off"
        }
    }

    var footer: LocalizedStringKey {
        switch self {
        case .bars: "The music from low notes to high, each bar springing with its part of the sound."
        case .glow: "The cover's colours drift behind it and swell with the music."
        case .halo: "Light blooms from behind the cover on every beat, most on the first of each bar."
        case .waveform: "The last few seconds of the music pass by, as Voice Memos draws a recording."
        case .off: "Just the song."
        }
    }

    /// Whether it's drawn around the cover, and so needs one large enough to surround.
    var surroundsCover: Bool { self == .glow || self == .halo }

    /// Whether it's a strip of its own, under the cover or the song, rather than light.
    var isStrip: Bool { self == .bars || self == .waveform }
}

/// Which way up Stage is on iPhone. Landscape by default: Stage is for a screen propped on
/// its side on a desk or a dock, and turns even with Rotation Lock on, as a video does.
enum StageOrientation: String, CaseIterable, Identifiable {
    case landscape, automatic, portrait

    var id: String { rawValue }
    static let storageKey = "stageOrientation"

    static var current: StageOrientation {
        UserDefaults.standard.string(forKey: storageKey).flatMap(StageOrientation.init) ?? .landscape
    }

    var title: LocalizedStringKey {
        switch self {
        case .landscape: "Landscape"
        case .automatic: "Automatic"
        case .portrait: "Portrait"
        }
    }

    #if os(iOS)
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .landscape: .landscape
        case .automatic: .allButUpsideDown
        case .portrait: .portrait
        }
    }
    #endif
}

/// Stage's other choices, as their stored keys.
enum StageOption {
    /// iPhone stays awake and bright while Stage is up. On by default.
    static let keepsScreenOn = "stageKeepsScreenOn"
    /// How many times the hint about the controls has shown, to stop after a few.
    static let hintsShown = "stageHintsShown"
    static let background = "stageBackground"
    static let showsAlbum = "stageShowsAlbum"
    static let showsProgress = "stageShowsProgress"
    static let showsNext = "stageShowsNext"
    static let showsClock = "stageShowsClock"
}

/// Whether Stage is up on iPhone, so it can be opened from Now Playing's menu, or at launch.
@Observable
final class StagePresenter {
    static let shared = StagePresenter()
    var isShowing = false
}

#if os(iOS)
extension StagePresenter {
    /// Which ways up the app may be: Stage's choice while it's up, and upright otherwise, as
    /// the rest of Tracks is.
    var orientations: UIInterfaceOrientationMask {
        isShowing ? StageOrientation.current.mask : .portrait
    }

    /// Turns the screen to suit, after Stage opens, closes, or its choice changes.
    func updateOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }
}
#endif

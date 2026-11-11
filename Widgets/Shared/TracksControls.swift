import WidgetKit
import SwiftUI
import AppIntents

// Controls for Control Center, the Lock Screen, the Action button and the Mac's menu bar.
// Their intents run in the app (see ControlIntents.swift), so the extension stays free of
// the capture stack, which broke this target's build when it was pulled in before.

/// Plays back today's radio songs so they count as real plays.
struct PlayBackTodayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PlayBackToday") {
            ControlWidgetButton(action: PlayBackTodayIntent()) {
                Label("Play Back Today", systemImage: "arrow.trianglehead.counterclockwise")
            }
        }
        .displayName("Play Back Today")
        .description("Plays today's radio songs so they count as real plays.")
    }
}

/// Starts Tracks Radio, or whichever mix or mood it's set to, without opening Tracks.
struct PlayInTracksControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "PlayInTracks", intent: PlayInTracksControlConfiguration.self) { configuration in
            ControlWidgetButton(action: StartPlayChoiceIntent(choice: configuration.choice)) {
                Label(configuration.choice.title, systemImage: configuration.choice.symbolName)
            }
        }
        .displayName("Play in Tracks")
        .description("Plays Tracks Radio, or the mix or mood you choose.")
    }
}

/// Keeps the radio song playing now, from anywhere, without opening Tracks.
struct SaveRadioSongControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "SaveRadioSong") {
            ControlWidgetButton(action: SaveRadioSongControlIntent()) {
                Label("Save Radio Song", systemImage: "radio")
            }
        }
        .displayName("Save Radio Song")
        .description("Adds the radio song playing now to your history.")
    }
}

/// Opens Tracks listening for the song playing nearby.
struct IdentifySongControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "IdentifySong") {
            ControlWidgetButton(action: IdentifySongIntent()) {
                Label("Identify Song", systemImage: "shazam.logo")
            }
        }
        .displayName("Identify Song")
        .description("Names the song playing nearby and finds it in your history.")
    }
}

import WidgetKit
import SwiftUI
import AppIntents

/// A control for Control Center, the Lock Screen and the Mac's menu bar.
///
/// There's no "save the song playing now" control: that intent needs the whole capture
/// stack, and pulling it into the widget extension broke this target's build before.
@available(iOS 18.0, macOS 26.0, *)
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

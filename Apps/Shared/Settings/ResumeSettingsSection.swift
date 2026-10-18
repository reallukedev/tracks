import SwiftUI
import TracksCore

/// Settings ▸ Play: whether the song that was on when Tracks closed waits for you, paused
/// where you left it, and for how long. Shared by the iPhone's page and the Mac's pane.
struct ResumeSettingsSection: View {
    @AppStorage(LastSessionStore.resumesKey) private var resumes = true
    @AppStorage(LastSessionStore.windowKey) private var window = ResumeWindow.standard

    var body: some View {
        Section {
            Toggle("Pick Up Where You Left Off", isOn: $resumes)
            if resumes {
                Picker("Keep the Song For", selection: $window) {
                    ForEach(ResumeWindow.allCases) { window in
                        Text(Self.name(window)).tag(window)
                    }
                }
            }
        } header: {
            Text("When You Come Back")
        } footer: {
            Text(footer)
                .contentTransition(.opacity)
        }
    }

    private var footer: String {
        guard resumes else {
            return String(localized: "Tracks opens with nothing playing.")
        }
        return switch window {
        case .always:
            String(localized: "The song that was on when you closed Tracks waits, paused where you left it, until you play something else.")
        default:
            String(localized: "The song that was on when you closed Tracks waits, paused where you left it, for \(Self.name(window).lowercased()). After that, Tracks opens with nothing playing.")
        }
    }

    static func name(_ window: ResumeWindow) -> String {
        switch window {
        case .oneHour: String(localized: "1 Hour")
        case .eightHours: String(localized: "8 Hours")
        case .oneDay: String(localized: "1 Day")
        case .threeDays: String(localized: "3 Days")
        case .oneWeek: String(localized: "1 Week")
        case .always: String(localized: "Always")
        }
    }
}

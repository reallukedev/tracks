import SwiftUI
import TracksCore

/// Says the last run ended without being quit, when, and offers the details for a bug report.
///
/// A notice in place rather than an alert. The HIG asks for no alert at launch and none that
/// only informs, and this is both: the app has already been reopened, so there's nothing to
/// decide. It stays until it's closed, so it's still there whenever the person next looks.
struct UnexpectedQuitNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(UnexpectedQuitMonitor.self) private var quitMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    /// How long "Copied" shows before the button reads "Copy Debug Info" again.
    private static let copiedFeedback: Duration = .seconds(2)

    var body: some View {
        if let notice = quitMonitor.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        title(for: notice)
                            .font(.subheadline.weight(.semibold))
                        detail(for: notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Wraps in the fixed-width menu bar window instead of truncating.
                    .fixedSize(horizontal: false, vertical: true)

                    Button(action: copy) {
                        Label(
                            copied ? LocalizedStringKey("Copied") : "Copy Debug Info",
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    }
                    .controlSize(.small)
                    .help("Copies details about Tracks and this Mac, without song titles or account details, to paste into a bug report.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Dismiss", systemImage: "xmark") {
                    withAnimation(reduceMotion ? nil : .default) { quitMonitor.dismiss() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }

    /// A full sentence, so sentence-style capitalization with a full stop.
    private func title(for notice: UnexpectedQuit) -> Text {
        let time = Self.moment(notice.stoppedAt)
        return notice.stopTimeIsExact
            ? Text("Tracks quit unexpectedly at \(time).")
            // Without the watchdog the time is the last one the app was seen running.
            : Text("Tracks quit unexpectedly around \(time).")
    }

    private func detail(for notice: UnexpectedQuit) -> Text {
        if notice.reopenedAutomatically {
            let gap = Duration.seconds(max(1, Int(notice.gap.rounded())))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
            return Text("It reopened by itself \(gap) later.")
        }
        return Text("Songs played until it reopened at \(Self.moment(notice.reopenedAt)) may be missing.")
    }

    /// The time alone for today, otherwise the day too.
    private static func moment(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func copy() {
        DebugInfo.copy(model: model, quitMonitor: quitMonitor)
        AccessibilityNotification.Announcement("Copied").post()
        copied = true
        Task {
            try? await Task.sleep(for: Self.copiedFeedback)
            copied = false
        }
    }
}

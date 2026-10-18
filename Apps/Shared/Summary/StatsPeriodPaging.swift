import SwiftUI
import Charts
import TracksCore

/// Moving Summary back and forward a week, month or year, handed down to the cards whose
/// charts can be swiped and the header that steps through periods.
struct StatsPeriodPaging: Sendable {
    /// Whether there's an earlier period with history, and a later one than this.
    var canGoBack: Bool
    var canGoForward: Bool
    /// -1 for an earlier period, +1 for a later one.
    var page: @MainActor @Sendable (Int) -> Void

    @MainActor
    func goBack() {
        if canGoBack { page(-1) }
    }

    @MainActor
    func goForward() {
        if canGoForward { page(1) }
    }
}

extension EnvironmentValues {
    /// Set by Summary. Nil elsewhere, where charts keep to the period they were given.
    @Entry var statsPaging: StatsPeriodPaging?
}

/// ‹ September 2026 ›: the period on show, with a step either side. The steps are what the
/// Mac and VoiceOver use; on iPhone the charts can be swiped as well.
struct PeriodPager: View {
    let summary: StatsSummary
    let paging: StatsPeriodPaging

    var body: some View {
        HStack(spacing: 2) {
            Button("Earlier", systemImage: "chevron.backward", action: paging.goBack)
                .disabled(!paging.canGoBack)
                .help(Text("Show the \(Text(summary.range.unitName)) before"))
            Text(summary.periodTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                // A month's full name at the largest sizes shrinks rather than being cut off.
                .minimumScaleFactor(0.7)
            Button("Later", systemImage: "chevron.forward", action: paging.goForward)
                .disabled(!paging.canGoForward)
                .help(Text("Show the \(Text(summary.range.unitName)) after"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.small)
        .fontWeight(.semibold)
        .animation(.snappy(duration: 0.2), value: summary.periodTitle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.periodTitle)
        .accessibilityHint(Text("Swipe up or down to change the \(Text(summary.range.unitName))."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: paging.goForward()
            case .decrement: paging.goBack()
            @unknown default: break
            }
        }
    }
}

extension View {
    /// Swiping sideways across a chart moves to the period before or after, as in Health and
    /// Screen Time. Reading a bar becomes touch and hold, then drag, so the two don't fight.
    /// The Mac keeps hovering to read, and pages with the steps beside the period's title.
    func periodSwipe(_ paging: StatsPeriodPaging?, selection: Binding<Date?>) -> some View {
        #if os(iOS)
        modifier(PeriodSwipe(paging: paging, selection: selection))
        #else
        chartXSelection(value: selection)
        #endif
    }
}

#if os(iOS)
private struct PeriodSwipe: ViewModifier {
    let paging: StatsPeriodPaging?
    @Binding var selection: Date?
    /// Where the bar on show was tapped, so a second tap on it puts the total back.
    @State private var tappedX: CGFloat?
    /// Swipes that changed the period, each felt as a page turns; one at either end, firmer.
    @State private var turns = 0
    @State private var stops = 0

    func body(content: Content) -> some View {
        if let paging {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    // A tap reads a bar and a quick sideways swipe changes the period. Neither
                    // holds on to the touch, so a drag that starts on a chart still scrolls the
                    // page, which a press-and-drag gesture here would stop.
                    Color.clear
                        .contentShape(.rect)
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            if selection != nil, let tappedX, abs(location.x - tappedX) < 12 {
                                selection = nil
                                self.tappedX = nil
                                return
                            }
                            selection = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                            tappedX = location.x
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { value in
                                    let across = value.translation.width
                                    guard abs(across) > 44, abs(across) > abs(value.translation.height) * 1.5 else { return }
                                    selection = nil
                                    tappedX = nil
                                    // Content follows the finger: swiping right brings in the past.
                                    let goesBack = across > 0
                                    guard goesBack ? paging.canGoBack : paging.canGoForward else {
                                        stops += 1
                                        return
                                    }
                                    turns += 1
                                    if goesBack { paging.goBack() } else { paging.goForward() }
                                }
                        )
                }
            }
            .sensoryFeedback(.selection, trigger: turns)
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.5), trigger: stops)
        } else {
            content.chartXSelection(value: $selection)
        }
    }
}
#endif

/// A period with nothing in it, with the steps still there so an empty month in the middle
/// of a history isn't a dead end.
struct NothingPlayedView: View {
    let summary: StatsSummary
    @Environment(\.statsPaging) private var paging

    var body: some View {
        VStack(spacing: 12) {
            if let paging {
                PeriodPager(summary: summary, paging: paging)
            }
            ContentUnavailableView(
                "Nothing Played \(summary.phrase)",
                systemImage: "waveform",
                description: summary.range == .allTime
                    ? Text("Songs appear here as Tracks keeps them.")
                    : Text("Try another \(Text(summary.range.unitName)), or a longer range.")
            )
        }
    }
}

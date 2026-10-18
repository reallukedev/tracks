import SwiftUI
import Charts
import TracksCore

extension RadioDay.Part {
    var title: String {
        switch self {
        case .earlyMorning: String(localized: "Early Morning")
        case .morning: String(localized: "Morning")
        case .afternoon: String(localized: "Afternoon")
        case .evening: String(localized: "Evening")
        case .night: String(localized: "Night")
        case .lateNight: String(localized: "Late Night")
        }
    }

    /// The part in a sentence: "calm at night".
    var phrase: String {
        switch self {
        case .earlyMorning: String(localized: "in the early morning")
        case .morning: String(localized: "in the morning")
        case .afternoon: String(localized: "in the afternoon")
        case .evening: String(localized: "in the evening")
        case .night: String(localized: "at night")
        case .lateNight: String(localized: "late at night")
        }
    }

    /// The sun rising, high and setting, then the moon.
    var symbol: String {
        switch self {
        case .earlyMorning: "sunrise"
        case .morning: "sun.min"
        case .afternoon: "sun.max"
        case .evening: "sunset"
        case .night: "moon"
        case .lateNight: "moon.stars"
        }
    }

    /// "5 AM to 8 AM", on a weekday: the weekend's later mornings are said once, in the footer.
    var hours: String {
        String(localized: "\(RadioDayWords.hour(startHour())) to \(RadioDayWords.hour(endHour()))")
    }
}

extension RadioDay.Feel {
    var title: String {
        switch self {
        case .calm: String(localized: "Calm")
        case .easy: String(localized: "Easy")
        case .balanced: String(localized: "Balanced")
        case .upbeat: String(localized: "Upbeat")
        case .energetic: String(localized: "Energetic")
        }
    }
}

/// What Through the Day says about a day, for the tuner, the Mac's Play pane and the page.
enum RadioDayWords {
    /// "Calm at night, upbeat in the afternoon.", or "Balanced all day."
    static func summary(_ day: RadioDay) -> String {
        if day.isFlat { return String(localized: "\(day[day.calmest].title) all day.") }
        return String(localized: "\(day[day.calmest].title) \(day.calmest.phrase), \(day[day.brightest].title.localizedLowercase) \(day.brightest.phrase).")
    }

    /// "calm at night and upbeat in the afternoon", to end a sentence.
    static func clause(_ day: RadioDay) -> String {
        if day.isFlat { return String(localized: "\(day[day.calmest].title.localizedLowercase) all day") }
        return String(localized: "\(day[day.calmest].title.localizedLowercase) \(day.calmest.phrase) and \(day[day.brightest].title.localizedLowercase) \(day.brightest.phrase)")
    }

    /// The Through the Day row's value on iPhone.
    static func value(_ day: RadioDay) -> String {
        day.isStandard ? String(localized: "Default") : String(localized: "Custom")
    }

    static let footer = String(localized: "Tracks Radio plays calmer or brighter songs in each part of the day, and eases from one to the next. On weekends, mornings come round an hour later.")

    /// An hour of the day as the clock says it: "5 AM", or "12 AM" for midnight at either end.
    static func hour(_ hour: Int) -> String {
        let calendar = Calendar.current
        let date = calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }
}

// MARK: - The chart

/// The day's energy from midnight to midnight, as the feels chosen draw it: a curve that rises
/// and falls through the day, coloured from calm indigo to energetic orange, with now marked.
/// Dragging across it reads out any time of day.
struct ThroughTheDayChart: View {
    let day: RadioDay
    @State private var selectedHour: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    #if os(macOS)
    private let height: CGFloat = 120
    #else
    /// Grows with the text a little, and no further than a curve still reads as one.
    @ScaledMetric(relativeTo: .body) private var scaledHeight: CGFloat = 150
    private var height: CGFloat { min(scaledHeight, 220) }
    #endif

    /// At accessibility sizes the axis words would crowd the curve out: the hours go to
    /// midnight and noon, and Calm and Energetic are left to the header and the rows.
    private var hourMarks: [Double] { typeSize.isAccessibilitySize ? [0, 12, 24] : [0, 6, 12, 18, 24] }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = Self.hour(of: context.date)
            let isWeekend = Calendar.current.isDateInWeekend(context.date)
            let shown = selectedHour ?? now
            VStack(alignment: .leading, spacing: 12) {
                header(at: shown, isWeekend: isWeekend, isNow: selectedHour == nil)
                chart(now: now, shown: shown, isWeekend: isWeekend)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tracks Radio Through the Day")
        .accessibilityValue(RadioDayWords.summary(day))
    }

    private func header(at hour: Double, isWeekend: Bool, isNow: Bool) -> some View {
        let part = RadioDay.Part(hour: Int(hour), isWeekend: isWeekend)
        return VStack(alignment: .leading, spacing: 2) {
            Text(isNow ? String(localized: "Now") : Self.time(hour))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .monospacedDigit()
            Text(day[part].title)
                .font(.title2.bold())
                .fontDesign(.rounded)
                .contentTransition(.opacity)
            Text(part.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .animation(reduceMotion ? nil : PlayMotion.value, value: day[part])
    }

    private func chart(now: Double, shown: Double, isWeekend: Bool) -> some View {
        let points = Self.samples.map { hour in (hour: hour, energy: day.energy(atHour: hour, isWeekend: isWeekend)) }
        return Chart {
            ForEach(points, id: \.hour) { point in
                AreaMark(
                    x: .value("Time", point.hour),
                    yStart: .value("Energy", 0),
                    yEnd: .value("Energy", point.energy)
                )
                .foregroundStyle(Self.gradient.opacity(0.22))
                .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.hour), y: .value("Energy", point.energy))
                    .foregroundStyle(Self.gradient)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            // Colours set outright: inside a chart, hierarchical styles take the accent.
            RuleMark(x: .value("Time", shown))
                .foregroundStyle(Color.primary.opacity(0.3))
                .lineStyle(StrokeStyle(lineWidth: 1))
            PointMark(x: .value("Time", shown), y: .value("Energy", day.energy(atHour: shown, isWeekend: isWeekend)))
                .symbol {
                    Circle()
                        .strokeBorder(Color.primary, lineWidth: 2.5)
                        .background(.background, in: .circle)
                        .frame(width: 12, height: 12)
                }
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: hourMarks) { value in
                AxisGridLine()
                // Midnight is said once, at the start: at the end too, it crowds 6 PM.
                if let hour = value.as(Double.self), hour < 24 {
                    AxisValueLabel(anchor: hour == 0 ? .topLeading : .top) {
                        Text(RadioDayWords.hour(Int(hour)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [RadioDay.Feel.calm.energy, RadioDay.Feel.energetic.energy]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                if !typeSize.isAccessibilitySize {
                    AxisValueLabel {
                        Text(value.as(Double.self) ?? 0 < 0.5 ? RadioDay.Feel.calm.title : RadioDay.Feel.energetic.title)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedHour)
        // A tick as the finger crosses into another part of the day, as other charts here do.
        .sensoryFeedback(.selection, trigger: selectedHour.map { RadioDay.Part(hour: Int($0), isWeekend: isWeekend) })
        .frame(height: height)
        .animation(reduceMotion ? nil : PlayMotion.value, value: day)
    }

    /// The day's colours, from calm at the foot of the chart to energetic at its head.
    private static let gradient = LinearGradient(colors: [.indigo, .pink, .orange], startPoint: .bottom, endPoint: .top)

    /// Every quarter of an hour, midnight to midnight: smooth enough for the easing between feels.
    private static let samples = stride(from: 0.0, through: 24.0, by: 0.25).map { $0 }

    private static func hour(of date: Date) -> Double {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
    }

    /// A time picked on the chart, to the quarter hour: "3:15 PM".
    private static func time(_ hour: Double) -> String {
        let minutes = Int((hour * 4).rounded()) * 15
        let date = Calendar.current.date(bySettingHour: (minutes / 60) % 24, minute: minutes % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - The feel of each part

/// Choosing a feel for one part of the day: its symbol, its name and hours, and a menu of
/// feels from Calm to Energetic.
private struct ThroughTheDayRow: View {
    let part: RadioDay.Part
    @Binding var feel: RadioDay.Feel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        #if os(macOS)
        HStack(spacing: SettingsSpacing.row) {
            Image(systemName: part.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            SettingsDetailRow(title: Text(part.title), detail: Text(part.hours)) {
                picker
                    .labelsHidden()
                    .fixedSize()
            }
        }
        #else
        picker
        #endif
    }

    private var picker: some View {
        Picker(selection: $feel) {
            ForEach(RadioDay.Feel.allCases) { feel in
                Text(feel.title).tag(feel)
            }
        } label: {
            // At accessibility sizes the symbol would squeeze the name into a narrow column.
            if typeSize.isAccessibilitySize {
                name
            } else {
                Label {
                    name
                } icon: {
                    Image(systemName: part.symbol)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .pickerStyle(.menu)
    }

    private var name: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(part.title)
            Text(part.hours)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// What the page and the sheet share: the day as stored, and changes that the radio playing
/// follows from its next song.
private struct ThroughTheDayEditing {
    let storedDay: Binding<String>
    let player: PlayerModel
    let reduceMotion: Bool

    var day: RadioDay { RadioDay(stored: storedDay.wrappedValue) }

    func feel(for part: RadioDay.Part) -> Binding<RadioDay.Feel> {
        Binding(
            get: { day[part] },
            set: { feel in update { $0[part] = feel } }
        )
    }

    func reset() {
        update { $0 = .standard }
    }

    private func update(_ change: (inout RadioDay) -> Void) {
        var day = day
        change(&day)
        withAnimation(reduceMotion ? nil : PlayMotion.value) {
            // The standard day is stored as nothing, so a later change to the standard is
            // picked up by anyone who never changed theirs.
            storedDay.wrappedValue = day.isStandard ? "" : day.stored
        }
        Task { await player.retuneTracksRadio() }
    }
}

#if os(iOS)
/// Through the Day, pushed from Time and Driving in the tuner: the day's curve, and a feel for
/// each part of it.
struct ThroughTheDayPage: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.radioDayKey) private var storedDay = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let editing = ThroughTheDayEditing(storedDay: $storedDay, player: player, reduceMotion: reduceMotion)
        let day = editing.day
        ScrollViewReader { proxy in
            form(day, editing: editing)
            #if DEBUG
            // -TracksThroughTheDayAnchor bottom opens the page scrolled to its foot, for screenshots.
            .task {
                guard UserDefaults.standard.string(forKey: "TracksThroughTheDayAnchor") == "bottom" else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo(Self.footID, anchor: .bottom)
            }
            #endif
        }
        .navigationTitle("Through the Day")
        .toolbarTitleDisplayMode(.inline)
    }

    private static let footID = "foot"

    private func form(_ day: RadioDay, editing: ThroughTheDayEditing) -> some View {
        Form {
            Section {
                ThroughTheDayChart(day: day)
                    .padding(.vertical, 6)
            }

            Section {
                ForEach(RadioDay.Part.allCases) { part in
                    ThroughTheDayRow(part: part, feel: editing.feel(for: part))
                }
            } header: {
                Text("Parts of the Day")
            } footer: {
                Text(RadioDayWords.footer)
                    .id(day.isStandard ? Self.footID : "")
            }

            if !day.isStandard {
                Section {
                    Button("Reset to Default", action: editing.reset)
                } footer: {
                    Text("Relaxing at night, gentle in the morning, brightest in the afternoon, and easing through the evening.")
                        .id(Self.footID)
                }
            }
        }
    }
}
#endif

#if os(macOS)
/// Through the Day on the Mac, in a popover from the tuner or a sheet from the Play pane: its
/// title in the content, the day's curve, a feel for each part, and Reset to Default and Done
/// at its foot.
struct ThroughTheDaySheet: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.radioDayKey) private var storedDay = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let editing = ThroughTheDayEditing(storedDay: $storedDay, player: player, reduceMotion: reduceMotion)
        let day = editing.day
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SettingsSpacing.tight) {
                Text("Through the Day")
                    .font(.title2.bold())
                Text("How calm or lively Tracks Radio plays in each part of the day.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    ThroughTheDayChart(day: day)
                        .padding(.vertical, 4)
                }
                Section {
                    ForEach(RadioDay.Part.allCases) { part in
                        ThroughTheDayRow(part: part, feel: editing.feel(for: part))
                    }
                } header: {
                    Text("Parts of the Day")
                } footer: {
                    Text(RadioDayWords.footer)
                }
            }
            .settingsPane()

            HStack(spacing: SettingsSpacing.standard) {
                if !day.isStandard {
                    Button("Reset to Default", action: editing.reset)
                        .help("Relaxing at night, gentle in the morning, brightest in the afternoon")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        // Changes apply as they're made, so Escape has nothing to undo: it closes, as Done does.
        .onExitCommand { dismiss() }
        #if DEBUG
        .onAppear {
            PlaySettingsScreenshot.applyAppearance()
            // -TracksAppearance light draws it light on a Mac set to dark, for screenshots.
            if UserDefaults.standard.string(forKey: "TracksAppearance") == "light" {
                NSApp.appearance = NSAppearance(named: .aqua)
            }
        }
        #endif
    }

    #if DEBUG
    /// `-TracksThroughTheDay YES` opens the sheet from the Play pane, for screenshots.
    static var opensAtLaunch: Bool { UserDefaults.standard.string(forKey: "TracksThroughTheDay") == "YES" }
    #else
    static let opensAtLaunch = false
    #endif
}
#endif

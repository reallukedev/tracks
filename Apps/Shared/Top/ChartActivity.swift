import SwiftUI
import Charts
import TracksCore

/// A chart's period at a glance, and each chart's own story of it. Songs say when you
/// listened, bar by bar, as Screen Time shows a week, and a bar opens its own chart. Artists
/// say who the listening went to. Albums say which record you went deepest into.
struct ChartActivityCard: View {
    let kind: ChartKind
    let period: ChartPeriod
    let activity: PeriodActivity
    let entries: [ChartEntry]
    /// Opens the chart of one bar, a day of a week or a month of a year.
    let open: (ChartPeriod) -> Void

    @State private var hovered: PeriodActivity.Bucket?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ChartStats(kind: kind, period: period, activity: activity)
            switch kind {
            case .songs:
                VStack(alignment: .leading, spacing: 8) {
                    caption
                    bars
                        .frame(height: Self.chartHeight)
                }
            case .artists:
                if activity.plays > 0, !entries.isEmpty {
                    ArtistShareBar(entries: entries, plays: activity.plays)
                }
            case .albums:
                if let deepest = entries.max(by: { ($0.songCount ?? 0, -$0.rank) < ($1.songCount ?? 0, -$1.rank) }),
                   (deepest.songCount ?? 0) > 1 {
                    DeepestListen(entry: deepest)
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: .rect(cornerRadius: 18, style: .continuous))
    }

    #if os(macOS)
    private static let chartHeight: CGFloat = 170
    private static let padding: CGFloat = 20
    #else
    private static let chartHeight: CGFloat = 150
    private static let padding: CGFloat = 16
    #endif

    // MARK: - Caption

    /// What the pointer is over, or how to go further in.
    private var caption: some View {
        Group {
            if let hovered {
                Text("\(Text(bucketName(hovered)).foregroundStyle(.primary).fontWeight(.semibold))  \(Text(PlayCountText.short(hovered.plays)))")
            } else if activity.bucketSpan != nil, activity.plays > 0 {
                #if os(macOS)
                Text("Click a \(Text(bucketNoun)) to see its chart.")
                #else
                Text("Tap a \(Text(bucketNoun)) to see its chart.")
                #endif
            } else {
                Text(verbatim: " ")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered?.id)
    }

    private var bucketNoun: LocalizedStringKey {
        switch period.span {
        case .day: "hour"
        case .week, .month: "day"
        case .year: "month"
        case .allTime: "year"
        }
    }

    private func bucketName(_ bucket: PeriodActivity.Bucket) -> String {
        switch period.span {
        case .day:
            bucket.start.formatted(.dateTime.hour())
        case .week:
            bucket.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .month:
            bucket.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .year:
            bucket.start.formatted(.dateTime.month(.wide))
        case .allTime:
            bucket.start.formatted(.dateTime.year())
        }
    }

    // MARK: - Bars

    private var unit: Calendar.Component {
        switch period.span {
        case .day: .hour
        case .week, .month: .day
        case .year: .month
        case .allTime: .year
        }
    }

    /// The average bar so far, drawn as a line once there's enough to average.
    private var average: Double? {
        let elapsed = activity.buckets.filter { $0.start <= .now }
        guard elapsed.count > 1, activity.plays > 0, period.span != .allTime else { return nil }
        return Double(elapsed.map(\.plays).reduce(0, +)) / Double(elapsed.count)
    }

    private var bars: some View {
        Chart {
            ForEach(activity.buckets) { bucket in
                BarMark(
                    x: .value("Time", bucket.start, unit: unit),
                    y: .value("Plays", bucket.plays)
                )
                .foregroundStyle(barStyle(bucket))
                .clipShape(.rect(cornerRadius: 3))
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        // The chart's card: its fill over the page.
                        AverageTag { Color.cardFill.background(Color.pageBackground) }
                    }
            }
        }
        .chartYScale(domain: 0...Double(max(activity.busiest, 3)))
        .chartXAxis { xAxis }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    #if os(macOS)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = bucket(at: location, proxy: proxy, geometry: geometry)
                        case .ended: hovered = nil
                        }
                    }
                    #endif
                    .onTapGesture { location in
                        guard let bucket = bucket(at: location, proxy: proxy, geometry: geometry) else { return }
                        openBucket(bucket)
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening by \(Text(bucketNoun))")
        .accessibilityValue(accessibilitySummary)
        .accessibilityChartDescriptor(ActivityDescriptor(buckets: activity.buckets, name: bucketName))
        // The bars open by tap alone; VoiceOver opens them from the actions instead.
        .accessibilityActions {
            if activity.bucketSpan != nil {
                ForEach(activity.buckets.filter { $0.start <= .now }) { bucket in
                    Button(bucketName(bucket)) { openBucket(bucket) }
                }
            }
        }
    }

    private func barStyle(_ bucket: PeriodActivity.Bucket) -> AnyShapeStyle {
        if let hovered {
            return hovered.id == bucket.id ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.35))
        }
        return AnyShapeStyle(Color.accentColor.opacity(bucket.start > .now ? 0.2 : 0.85))
    }

    @AxisContentBuilder
    private var xAxis: some AxisContent {
        switch period.span {
        case .day:
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        case .week:
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
            }
        case .month:
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day())
            }
        case .year:
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
            }
        case .allTime:
            AxisMarks(values: .stride(by: .year)) { _ in
                AxisValueLabel(format: .dateTime.year(), centered: true)
            }
        }
    }

    private func bucket(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> PeriodActivity.Bucket? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = location.x - geometry[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return activity.buckets.first { $0.start <= date && date < $0.end }
    }

    private func openBucket(_ bucket: PeriodActivity.Bucket) {
        guard let span = activity.bucketSpan, bucket.start <= .now else { return }
        hovered = nil
        open(ChartPeriod.containing(bucket.start, span: span))
    }

    private var accessibilitySummary: Text {
        guard let top = activity.buckets.max(by: { $0.plays < $1.plays }), top.plays > 0 else {
            return Text("No listening")
        }
        return Text("Most on \(bucketName(top)), with \(PlayCountText.short(top.plays))")
    }
}

/// The bars for VoiceOver's Audio Graphs.
private struct ActivityDescriptor: AXChartDescriptorRepresentable {
    let buckets: [PeriodActivity.Bucket]
    let name: (PeriodActivity.Bucket) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let names = buckets.map(name)
        let x = AXCategoricalDataAxisDescriptor(title: String(localized: "Time"), categoryOrder: names)
        let most = Double(buckets.map(\.plays).max() ?? 0)
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Plays"), range: 0...max(most, 1), gridlinePositions: []) { value in
            PlayCountText.short(Int(value))
        }
        let series = AXDataSeriesDescriptor(name: String(localized: "Plays"), isContinuous: false, dataPoints: zip(names, buckets).map {
            AXDataPoint(x: $0.0, y: Double($0.1.plays))
        })
        return AXChartDescriptor(title: String(localized: "Listening"), summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

/// The period's numbers, led by the one each chart is about: plays for songs, with how they
/// compare with the period before; how many artists, and how many were new; how many
/// albums, and how many songs from them.
struct ChartStats: View {
    let kind: ChartKind
    let period: ChartPeriod
    let activity: PeriodActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            figures
            // About listening time, so on a line of its own rather than under the lead figure.
            if let comparison {
                comparison
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var figures: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 28) {
                lead
                Divider().frame(height: 44)
                ForEach(others.enumerated(), id: \.offset) { _, stat in
                    small(stat)
                }
                Spacer(minLength: 0)
            }
            // Two even columns, so the second lines up at the card's middle whatever the figures.
            Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    lead.frame(maxWidth: .infinity, alignment: .leading)
                    small(others[0]).frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    small(others[1]).frame(maxWidth: .infinity, alignment: .leading)
                    small(others[2]).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private struct Stat {
        let title: LocalizedStringKey
        let value: String
        var help: LocalizedStringKey?
    }

    private var time: Stat {
        Stat(title: "Listening Time", value: Format.listening(activity.seconds))
    }

    private var plays: Stat { Stat(title: "Plays", value: activity.plays.formatted()) }

    /// The three beside the lead.
    private var others: [Stat] {
        switch kind {
        case .songs:
            [time, Stat(title: "Songs", value: activity.songs.formatted()), Stat(title: "New to You", value: activity.newSongs.formatted(), help: "Songs you heard for the first time")]
        case .artists:
            [Stat(title: "New Artists", value: activity.newArtists.count.formatted(), help: "Artists you heard for the first time"), plays, time]
        case .albums:
            [Stat(title: "Songs", value: activity.songs.formatted()), plays, time]
        }
    }

    private var lead: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch kind {
            case .songs:
                label("Plays")
                big(activity.plays)
            case .artists:
                label("Artists")
                big(activity.artists)
            case .albums:
                label("Albums")
                big(activity.albums)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func big(_ value: Int) -> some View {
        Text(value.formatted())
            .font(.system(.largeTitle, design: .rounded).weight(.bold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(value)))
    }

    private func small(_ stat: Stat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(stat.title)
            Text(stat.value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .help(stat.help.map { Text($0) } ?? Text(stat.title))
        .accessibilityElement(children: .combine)
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    /// "↑ 50% more listening than this time last week": listening time against the period
    /// before, cut to the same point while this one is still under way.
    private var comparison: Text? {
        guard let change = activity.change else { return nil }
        let percent = abs(change).formatted(.percent.precision(.fractionLength(0)))
        let before = period.isCurrent() ? Text("this time \(Text(period.beforeName))") : Text(period.beforeName)
        if abs(change) < 0.005 {
            return Text("About the same as \(before)")
        }
        let arrow = Image(systemName: change > 0 ? "arrow.up" : "arrow.down")
        return change > 0
            ? Text("\(arrow) \(percent) more listening than \(before)")
            : Text("\(arrow) \(percent) less listening than \(before)")
    }
}

extension ChartPeriod {
    /// The period before, as a sentence ends with it: "last week", or "the week before" for
    /// a period that isn't this one.
    var beforeName: LocalizedStringKey {
        if isCurrent() {
            return switch span {
            case .day: "yesterday"
            case .week: "last week"
            case .month: "last month"
            case .year: "last year"
            case .allTime: "before"
            }
        }
        return switch span {
        case .day: "the day before"
        case .week: "the week before"
        case .month: "the month before"
        case .year: "the year before"
        case .allTime: "before"
        }
    }

    /// The dates the title doesn't say: "Sep 20 – 26" under "This Week", the date under
    /// "Today". Nil where the title already says it all.
    func dates(now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let interval else { return nil }
        let last = interval.end.addingTimeInterval(-1)
        switch span {
        case .day:
            let title = title(now: now, calendar: calendar)
            let full = interval.start.formatted(.dateTime.weekday(.wide).month(.wide).day())
            return title == full ? nil : full
        case .week:
            let sameYear = calendar.isDate(interval.start, equalTo: now, toGranularity: .year)
            return (interval.start..<last).formatted(sameYear ? .interval.month(.abbreviated).day() : .interval.month(.abbreviated).day().year())
        case .month, .year, .allTime:
            return nil
        }
    }
}

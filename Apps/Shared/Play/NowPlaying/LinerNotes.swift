import SwiftUI
import TracksCore

/// The back of the sleeve: your history with the song playing. How many times you've heard
/// it, since when and from where, a year of it month by month, and when in the day it's
/// yours. The one thing on Now Playing only Tracks can say.
///
/// Inks with the hierarchical styles, so it reads on a cover's colour (the iPhone's sleeve)
/// and on the window (the Mac's panel) alike.
struct LinerNotes: View {
    let track: PlayerTrack
    /// Roomy in the Mac's panel; tight enough to fit the back of the iPhone's cover.
    var isCompact = false
    /// On the back of a cover, which is square: the year's bars take the room there is, and
    /// the way on sits at the foot of the card.
    var fillsCard = false
    let onShowStats: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var story: SongStory?
    /// The song and history `story` was read for, so a new song doesn't flash the old one's.
    @State private var readFor: String?

    var body: some View {
        Group {
            if fillsCard {
                // A cover's back is only so big, the more so at the largest text sizes. What
                // doesn't fit gives way from the least said: the later facts, then the rest
                // of them, then the year's bars. The count and the way on always stay.
                ViewThatFits(in: .vertical) {
                    notes(facts: .max)
                    notes(facts: 2)
                    notes(facts: 1)
                    notes(facts: 0)
                    notes(facts: 0, showsBars: false)
                }
            } else {
                notes(facts: .max)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsCard ? .infinity : nil, alignment: .topLeading)
        .task(id: key) { await read() }
    }

    /// The notes with the first `facts` of the story's facts, and with or without the bars.
    private func notes(facts limit: Int, showsBars: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: isCompact ? 12 : 20) {
            header
            if let story, readFor == key {
                if showsBars {
                    MonthBars(months: story.months, busiest: story.busiestMonth)
                        .frame(minHeight: isCompact ? 72 : 88, maxHeight: fillsCard ? 220 : (isCompact ? 72 : 88))
                }
                if limit > 0 {
                    facts(story, limit: limit)
                }
            } else if readFor == key, showsBars {
                Text("Tracks keeps this song once you've heard enough of it to count. Its story starts here.")
                    .font(isCompact ? .subheadline : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if fillsCard {
                Spacer(minLength: 0)
            }
            Button(action: onShowStats) {
                Label("Your Stats", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            #if os(iOS)
            .controlSize(isCompact ? .regular : .large)
            #endif
        }
    }

    /// Which song, against which history: a play kept moves the revision on.
    private var key: String {
        "\(track.songIdentity)|\(model.library.revision)"
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your History")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            let plays = readFor == key ? story?.plays ?? 0 : nil
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let plays, plays > 0 {
                    countText(plays)
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(plays)))
                } else if plays != nil {
                    Text("First Listen")
                        .font(.system(.title, design: .rounded).weight(.bold))
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: plays)
            .accessibilityElement(children: .combine)
        }
    }

    /// "13 plays" as one localized phrase, its number set large in SF Rounded and its word
    /// beside it, wherever the language puts the number.
    private func countText(_ plays: Int) -> Text {
        let phrase = String(AttributedString(localized: "^[\(plays) play](inflect: true)").characters)
        let number = plays.formatted()
        let big = Font.system(.largeTitle, design: .rounded).weight(.bold)
        let small = isCompact ? Font.headline : .title3.weight(.semibold)
        guard let range = phrase.range(of: number) else {
            return Text(phrase).font(small)
        }
        let before = String(phrase[..<range.lowerBound])
        let after = String(phrase[range.upperBound...])
        return Text("\(Text(before).font(small).foregroundStyle(.secondary))\(Text(number).font(big))\(Text(after).font(small).foregroundStyle(.secondary))")
    }

    // MARK: - Facts

    /// The first `limit` of the facts the story has, in the order they matter.
    private func facts(_ story: SongStory, limit: Int = .max) -> some View {
        var rows: [(label: LocalizedStringKey, value: Text)] = [("First Heard", firstHeard(story))]
        if let last = story.lastHeard {
            rows.append(("Last Heard", Text(Self.relative(last))))
        }
        if let usual = story.usualTime {
            rows.append(("Usually", Text("\(Image(systemName: usual.symbol)) \(Text(usual.phrase))")))
        }
        if let rank = story.rankThisMonth {
            rows.append(("This Month", Text("No. \(rank) of your songs")))
        }
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: isCompact ? 6 : 10) {
            ForEach(rows.prefix(limit).indices, id: \.self) { index in
                row(rows[index].label, value: rows[index].value)
            }
        }
        .font(isCompact ? .footnote : .callout)
    }

    private func row(_ label: LocalizedStringKey, value: Text) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            value
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func firstHeard(_ story: SongStory) -> Text {
        let when = story.firstHeard.formatted(.dateTime.month(.abbreviated).day().year())
        if let station = story.firstStation {
            return Text("\(when), on \(station)")
        }
        return Text(when)
    }

    /// "Today", "Yesterday", "Sunday" within the week, then the date.
    static func relative(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    // MARK: - Reading

    private func read() async {
        let key = key
        let identity = track.songIdentity
        let history = model.library.history
        // The play being made now isn't "the last time".
        let since = player.trackStartedAt
        let next = await OffMainActor.run {
            SongStories.story(of: identity, in: history, listeningSince: since)
        }
        guard !Task.isCancelled else { return }
        story = next
        readFor = key
    }
}

/// A year of plays, a bar a month, this month brightest. A month without plays is a dot, so
/// the year still reads as twelve months.
struct MonthBars: View {
    let months: [SongStory.MonthPlays]
    let busiest: Int

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(months) { month in
                    let isCurrent = month.id == months.last?.id
                    GeometryReader { proxy in
                        let fraction = Double(month.plays) / Double(busiest)
                        let width = min(proxy.size.width * 0.5, 8)
                        // An empty month is a dot, as wide as a bar.
                        let height = month.plays == 0 ? width : max(width, proxy.size.height * fraction)
                        Capsule()
                            .fill(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .opacity(month.plays == 0 ? 0.35 : 1)
                            .frame(width: width, height: height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(months) { month in
                    Text(month.start.formatted(.dateTime.month(.narrow)))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(month.id == months.last?.id ? .primary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Plays by month")
        .accessibilityValue(summary)
    }

    private var summary: Text {
        guard let top = months.max(by: { $0.plays < $1.plays }), top.plays > 0 else {
            return Text("None in the last year")
        }
        return Text("Most in \(top.start.formatted(.dateTime.month(.wide))), with ^[\(top.plays) play](inflect: true)")
    }
}

extension DayPart {
    /// "in the evening", for a sentence.
    var phrase: LocalizedStringKey {
        switch self {
        case .morning: "in the morning"
        case .afternoon: "in the afternoon"
        case .evening: "in the evening"
        case .night: "at night"
        }
    }
}


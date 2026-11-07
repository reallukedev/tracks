import SwiftUI
import TracksCore

// MARK: - Your History

/// Your plays of the song: how many and when, over time, from where, and at what time of day.
struct SongInfoHistorySection: View {
    let part: SongInfoPart<SongInfoHistory>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Your History")
            switch part {
            case .loaded(let history):
                if let profile = history?.profile {
                    played(profile, dayParts: history?.dayParts)
                } else {
                    Card {
                        Text("You haven't played this song yet. Once you do, Tracks keeps every play here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .loading, .offline:
                StatStrip(items: [
                    .init(title: "Plays", value: "00"),
                    .init(title: "First Heard", value: "00 Mmm"),
                    .init(title: "Last Heard", value: "00 Mmm"),
                ])
                .redacted(reason: .placeholder)
                .accessibilityHidden(true)
            }
        }
    }

    private func played(_ profile: SongProfile, dayParts: [DayPartPlays]?) -> some View {
        let song = profile.song
        let items: [StatStrip.Item] = song.count == 1
            ? [.init(title: "Plays", value: song.count.formatted()), .init(title: "Played", value: Format.shortDate(song.firstHeard))]
            : [
                .init(title: "Plays", value: song.count.formatted()),
                .init(title: "First Heard", value: Format.shortDate(song.firstHeard)),
                .init(title: "Last Heard", value: Format.shortDate(song.lastHeard)),
            ]
        return VStack(alignment: .leading, spacing: Metrics.cardSpacing) {
            StatStrip(items: items)
            if profile.timeline.count(where: { $0.count > 0 }) > 1 {
                PlaysOverTimeCard(timeline: profile.timeline, unit: profile.timelineUnit)
            }
            if HowYouHeardItCard.isWorthShowing(sources: profile.sources, stations: profile.stations) {
                HowYouHeardItCard(sources: profile.sources, stations: profile.stations)
            }
            if let dayParts {
                SongTimeOfDayCard(parts: dayParts)
            }
        }
    }
}

/// Morning to night, each part's share of the song's plays. At the largest text sizes each
/// part's bar runs under its name rather than squeezing beside it.
private struct SongTimeOfDayCard: View {
    let parts: [DayPartPlays]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.plays })
        let busiest = parts.map(\.plays).max() ?? 0
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardLabel(title: "Time of Day", systemImage: "clock", tint: .accentColor)
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(parts) { part in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    name(part, busiest: busiest)
                                    Spacer(minLength: 8)
                                    share(part, total: total)
                                }
                                bar(part, busiest: busiest)
                            }
                            .modifier(PartAccessibility(part: part))
                        }
                    }
                    .font(.subheadline)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        ForEach(parts) { part in
                            GridRow {
                                name(part, busiest: busiest)
                                    .lineLimit(1)
                                bar(part, busiest: busiest)
                                    .frame(minWidth: 60)
                                share(part, total: total)
                                    .gridColumnAlignment(.trailing)
                            }
                            .font(.subheadline)
                            .modifier(PartAccessibility(part: part))
                        }
                    }
                }
            }
        }
    }

    private func name(_ part: DayPartPlays, busiest: Int) -> some View {
        Label {
            Text(part.part.name)
        } icon: {
            Image(systemName: part.part.symbol)
                .foregroundStyle(part.plays == busiest && busiest > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    private func bar(_ part: DayPartPlays, busiest: Int) -> some View {
        ProportionBar(
            fraction: Double(part.plays) / Double(max(1, busiest)),
            style: part.plays == busiest ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.45))
        )
    }

    private func share(_ part: DayPartPlays, total: Int) -> some View {
        Text(Format.percent(Double(part.plays) / Double(total)))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private struct PartAccessibility: ViewModifier {
        let part: DayPartPlays

        func body(content: Content) -> some View {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(part.part.name))
                .accessibilityValue(Text("^[\(part.plays) play](inflect: true)"))
        }
    }
}

// MARK: - Details

/// The facts about the song, from whichever source has each: Apple Music or your file first,
/// then what the history looked up, then MusicBrainz.
struct SongInfoDetailsSection: View {
    let subject: SongInfoSubject
    let about: SongInfoPart<SongAbout>
    var metadata: SongMetadata?
    var credits: SongCredits?
    var versions: SongVersions?

    var body: some View {
        if about.isLoading {
            section { SkeletonRows(count: 5) }
        } else {
            let rows = facts
            let note = about.value?.note
            if !rows.isEmpty || note != nil {
                section {
                    VStack(spacing: 0) {
                        if let note {
                            AboutNote(title: subject.title, text: note)
                                .font(.subheadline)
                                .padding(.horizontal, Metrics.cardPadding)
                                .padding(.vertical, 12)
                            if !rows.isEmpty { InsetDivider() }
                        }
                        ForEach(rows.enumerated(), id: \.element.label) { index, row in
                            if index > 0 { InsetDivider() }
                            FactRow(label: row.label, value: row.value, isSelectable: row.isSelectable)
                        }
                    }
                }
            }
        }
    }

    private func section(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Details")
            Card(padding: 0) { content() }
        }
    }

    struct Fact: Equatable {
        let label: String
        let value: String
        var isSelectable = false
    }

    var facts: [Fact] {
        let about = about.value
        var facts: [Fact] = []
        if let number = about?.trackNumber, number > 0 {
            let value = about?.trackCount.map { String(localized: "\(number) of \($0)") } ?? number.formatted()
            facts.append(Fact(label: String(localized: "Track"), value: value))
        }
        if let released = about?.released {
            facts.append(Fact(label: String(localized: "Released"), value: released.formatted(SongAbout.releaseDateStyle)))
        } else if let year = about?.year ?? metadata?.releaseYear ?? credits?.firstReleaseYear {
            facts.append(Fact(label: String(localized: "Year"), value: Format.year(year)))
        }
        if let genre = about?.genre ?? metadata?.genre ?? credits?.genres.first {
            facts.append(Fact(label: String(localized: "Genre"), value: genre))
        }
        if let composer = about?.composer {
            facts.append(Fact(label: String(localized: "Composer"), value: composer))
        }
        if let length = about?.length, length > 0 {
            let pattern: Duration.TimeFormatStyle.Pattern = length >= 3_600 ? .hourMinuteSecond : .minuteSecond
            facts.append(Fact(label: String(localized: "Length"), value: Duration.seconds(length).formatted(.time(pattern: pattern))))
        }
        if let key = versions?.key {
            facts.append(Fact(label: String(localized: "Key"), value: key))
        }
        if let hasLyrics = about?.hasLyrics {
            facts.append(Fact(label: String(localized: "Lyrics"), value: hasLyrics ? String(localized: "Available") : String(localized: "Not Available")))
        }
        if let label = about?.recordLabel {
            facts.append(Fact(label: String(localized: "Record Label"), value: label))
        }
        if let copyright = about?.copyright {
            facts.append(Fact(label: String(localized: "Copyright"), value: copyright))
        }
        if let isrc = about?.isrc {
            facts.append(Fact(label: String(localized: "ISRC"), value: isrc, isSelectable: true))
        }
        return facts
    }
}

/// A label and its value, the value right-aligned and wrapping under itself.
private struct FactRow: View {
    let label: String
    let value: String
    var isSelectable = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
        layout {
            Text(label)
                .foregroundStyle(.secondary)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            valueText
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var valueText: some View {
        if isSelectable {
            Text(verbatim: value)
                .monospaced()
                .textSelection(.enabled)
        } else {
            Text(verbatim: value)
        }
    }
}

// MARK: - Credits

/// Who made the recording, in Apple Music's groups.
struct SongInfoCreditsSection: View {
    let part: SongInfoPart<SongCredits>
    @State private var showsAll = false

    /// People shown before Show All: a classical recording can list a whole orchestra.
    private static let collapsedCount = 8

    var body: some View {
        switch part {
        case .loading:
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Credits")
                Card(padding: 0) { SkeletonRows(count: 3, isStacked: true) }
            }
        case .loaded(let credits?) where !credits.sections.isEmpty:
            let total = credits.sections.reduce(0) { $0 + $1.credits.count }
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Credits") {
                    if total > Self.collapsedCount {
                        Button(showsAll ? "Show Less" : "Show All") { showsAll.toggle() }
                    }
                }
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(shown(credits.sections)) { section in
                            GroupTitle(title: section.kind.title)
                            ForEach(section.credits) { credit in
                                CreditRow(credit: credit)
                                if credit.id != section.credits.last?.id { InsetDivider() }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        default:
            EmptyView()
        }
    }

    /// The first few people across the groups, or all of them.
    private func shown(_ sections: [CreditSection]) -> [CreditSection] {
        guard !showsAll else { return sections }
        var left = Self.collapsedCount
        return sections.compactMap { section in
            guard left > 0 else { return nil }
            let credits = Array(section.credits.prefix(left))
            left -= credits.count
            return CreditSection(kind: section.kind, credits: credits)
        }
    }
}

private struct CreditRow: View {
    let credit: Credit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(credit.name)
                .font(.body)
            Text(credit.roles.map(\.title).formatted(.list(type: .and, width: .narrow)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Samples

/// What the song borrows and who borrowed from it. Each opens that song's own info.
struct SongInfoSamplesSection: View {
    let credits: SongCredits?

    var body: some View {
        if let credits, credits.hasSamples {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Samples")
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !credits.samples.isEmpty {
                            LinkGroup(title: "Contains Samples Of", links: credits.samples)
                        }
                        if !credits.sampledBy.isEmpty {
                            LinkGroup(title: "Sampled In", links: credits.sampledBy)
                        }
                        if !credits.mashups.isEmpty {
                            LinkGroup(title: "Mashed Up In", links: credits.mashups)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

// MARK: - Versions

/// The artist's other recordings of the song, and other artists' covers of it.
struct SongInfoVersionsSection: View {
    let subject: SongInfoSubject
    let versions: SongVersions?

    var body: some View {
        if let versions, !versions.versions.isEmpty || !versions.covers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Versions & Covers")
                Card(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !versions.versions.isEmpty {
                            LinkGroup(title: "Other Versions", links: versions.versions, current: subject)
                        }
                        if !versions.covers.isEmpty {
                            LinkGroup(title: "Covers", links: versions.covers, current: subject)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

/// A titled group of recordings in a card, the first few with Show All for the rest.
private struct LinkGroup: View {
    let title: LocalizedStringKey
    let links: [RecordingLink]
    /// The song the page is about: a live take of it is a row of its own, not a way back to it.
    var current: SongInfoSubject?
    @State private var showsAll = false

    private static let collapsedCount = 5

    var body: some View {
        let shown = showsAll ? links : Array(links.prefix(Self.collapsedCount))
        HStack(alignment: .firstTextBaseline) {
            GroupTitle(title: title)
            Spacer(minLength: 8)
            if links.count > Self.collapsedCount {
                Button(showsAll ? "Show Less" : "Show All") { showsAll.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .font(.footnote)
                    .padding(.horizontal, Metrics.cardPadding)
            }
        }
        ForEach(shown) { link in
            let subject = SongInfoSubject(link)
            SongLinkRow(
                title: link.title,
                detail: detail(of: link),
                subject: subject.identity == current?.identity ? nil : subject
            )
            if link.id != shown.last?.id { InsetDivider() }
        }
    }

    /// "Ray Charles · 1954", or "Live, 2005: Abbey Road · 2005" for the artist's own take.
    private func detail(of link: RecordingLink) -> String {
        let isOwn = current.map { StatsCalculator.folded($0.artistName) == StatsCalculator.folded(link.artistName) } ?? false
        let year = link.year.map(Format.year)
        let parts = isOwn ? [link.detail, year] : [link.artistName, link.detail, year]
        return parts.compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Last.fm

/// How Last.fm's listeners tag the song, its wiki, and the songs they play with it.
struct SongInfoLastFMSection: View {
    let subject: SongInfoSubject
    let part: SongInfoPart<LastFMTrackInfo>

    var body: some View {
        switch part {
        case .loading:
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Last.fm")
                Card(padding: 0) { LastFMSkeleton() }
            }
        case .loaded(let info?):
            if !info.tags.isEmpty || info.summary != nil || info.url != nil {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Last.fm")
                    Card(padding: 0) { details(info) }
                }
            }
            if !info.similar.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader("Listeners Also Play")
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(info.similar) { song in
                                SongLinkRow(title: song.title, detail: song.artistName, subject: SongInfoSubject(song))
                                if song.id != info.similar.last?.id { InsetDivider() }
                            }
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func details(_ info: LastFMTrackInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !info.tags.isEmpty {
                TagFlow(spacing: 6) {
                    ForEach(info.tags, id: \.self) { tag in
                        TagCapsule(text: tag)
                    }
                }
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.vertical, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Tags: \(info.tags.formatted(.list(type: .and)))"))
            }
            if let summary = info.summary {
                if !info.tags.isEmpty { InsetDivider() }
                AboutNote(title: subject.title, text: summary)
                    .font(.subheadline)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 12)
            }
            if let url = info.url {
                if !info.tags.isEmpty || info.summary != nil { InsetDivider() }
                Link(destination: url) {
                    HStack {
                        Text("View on Last.fm")
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 11)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .font(.subheadline)
            }
        }
    }
}

private struct TagCapsule: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.fill.tertiary, in: .capsule)
    }
}

/// Tags over a few lines of wiki, the shape Last.fm's card usually takes.
private struct LastFMSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(["Indie Pop", "Dream Pop", "Chill"], id: \.self) { TagCapsule(text: $0) }
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.vertical, 12)
            InsetDivider()
            Text(verbatim: "A song by an artist, written over one winter and played on the radio long before it was ever released as a single.")
                .font(.subheadline)
                .lineLimit(3)
                .padding(.horizontal, Metrics.cardPadding)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

// MARK: - Footnote

/// Where credits come from, and what's missing while offline.
struct SongInfoFootnote: View {
    let info: SongInfoModel
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if info.isOffline {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "wifi.slash")
                    Text(info.lastFM == .offline
                        ? "Credits, samples, versions and Last.fm need an internet connection."
                        : "Credits, samples and versions need an internet connection.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                Button("Try Again", action: retry)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            if let credits = info.credits.value, !credits.isEmpty, let url = credits.pageURL {
                Text("Credits, samples and versions from [MusicBrainz](\(url)), the open music encyclopedia.")
                    .foregroundStyle(.secondary)
                    .tint(.secondary)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 4)
    }
}

// MARK: - Shared pieces

/// A song that opens its own info: a sample, or a song Last.fm's listeners also play.
struct SongLinkRow: View {
    let title: String
    let detail: String
    /// Nil for a row that only names its song.
    let subject: SongInfoSubject?

    var body: some View {
        if let subject {
            NavigationLink(value: subject) {
                label(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows this song's info")
        } else {
            label(showsChevron: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 10)
        .contentShape(.rect)
    }
}

/// "PERFORMERS", over a group of rows inside a card.
struct GroupTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct InsetDivider: View {
    var inset: CGFloat = Metrics.cardPadding

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// Grey bars where a card's rows will be, the height of the real ones.
struct SkeletonRows: View {
    let count: Int
    /// A name over its roles, as credits are, rather than a label beside its value.
    var isStacked = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if index > 0 { InsetDivider() }
                Group {
                    if isStacked {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "Placeholder Name").font(.body)
                            Text(verbatim: "Producer, Songwriter").font(.subheadline)
                        }
                        .padding(.vertical, 9)
                    } else {
                        HStack {
                            Text(verbatim: "Released")
                            Spacer()
                            Text(verbatim: "May 17, 2024")
                        }
                        .font(.subheadline)
                        .padding(.vertical, 11)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.cardPadding)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

/// Tags or badges left to right, wrapping onto as many lines as they need.
struct TagFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Words

extension CreditSection.Kind {
    var title: LocalizedStringKey {
        switch self {
        case .performers: "Performers"
        case .composition: "Composition & Lyrics"
        case .production: "Production & Engineering"
        }
    }
}

extension CreditRole {
    /// Apple Music's words for the role: "Co-Producer", "Assistant Engineer", "Turntable".
    var title: String {
        switch kind {
        case .featured: return String(localized: "Featured Artist")
        case .performer: return String(localized: "Performer")
        case .vocals:
            guard let detail else { return String(localized: "Vocals") }
            if detail.localizedCaseInsensitiveContains("vocal") { return detail.capitalized }
            return String(localized: "\(detail.capitalized) Vocals")
        case .instrument: return detail?.capitalized ?? String(localized: "Instruments")
        case .orchestra: return String(localized: "Orchestra")
        case .conductor: return String(localized: "Conductor")
        case .songwriter: return String(localized: "Songwriter")
        case .composer: return String(localized: "Composer")
        case .lyricist: return String(localized: "Lyricist")
        case .arranger: return String(localized: "Arranger")
        case .producer:
            switch detail {
            case "co": return String(localized: "Co-Producer")
            case "executive": return String(localized: "Executive Producer")
            case "associate": return String(localized: "Associate Producer")
            case "additional": return String(localized: "Additional Producer")
            default: return String(localized: "Producer")
            }
        case .mixing: return String(localized: "Mixing Engineer")
        case .engineer: return detail == "assistant" ? String(localized: "Assistant Engineer") : String(localized: "Engineer")
        case .recording: return String(localized: "Recording Engineer")
        case .mastering: return String(localized: "Mastering Engineer")
        case .programming: return String(localized: "Programming")
        }
    }
}

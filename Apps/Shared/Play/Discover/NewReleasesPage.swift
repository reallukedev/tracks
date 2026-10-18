import SwiftUI
import MusicKit
import TracksCore

/// What your artists have put out lately, and what they have coming.
///
/// The newest leads, large, with how much you play whoever made it. What's coming follows,
/// then everything else by when it came out. A release you haven't heard any of carries a
/// dot, as an episode you haven't played does in Podcasts, so a glance says what's waiting.
struct NewReleasesPage: View {
    @Environment(Discovery.self) private var discovery
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.all
    @State private var yours = YourReleases()

    enum Filter: String, CaseIterable, Identifiable {
        case all, albums, singles
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .albums: "Albums"
            case .singles: "Singles & EPs"
            }
        }

        func includes(_ release: Discovery.Release) -> Bool {
            switch self {
            case .all: true
            case .albums: release.kind == .album
            case .singles: release.kind != .album
            }
        }
    }

    var body: some View {
        let releases = discovery.releases.filter(filter.includes)
        let upcoming = releases.filter(\.isUpcoming).sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        let out = releases.filter { !$0.isUpcoming }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let featured = out.first
        ScrollView {
            VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                #if os(iOS)
                filterPicker
                    .padding(.horizontal, PlayMetrics.margin)
                #endif

                if let featured {
                    FeaturedRelease(release: featured, plays: yours.plays(of: featured), isHeard: yours.hasHeard(featured))
                }

                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        header("Coming Soon", detail: "Not out yet. Add them now, and they'll be in your library the day they are.")
                            .padding(.horizontal, PlayMetrics.margin)
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: PlayMetrics.shelfSpacing) {
                                ForEach(upcoming) { release in
                                    ReleaseTile(release: release, side: PlayMetrics.tile)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
                        .scrollTargetBehavior(.viewAligned)
                        .scrollIndicators(.hidden)
                    }
                }

                ForEach(Period.allCases) { period in
                    let items = out.dropFirst().filter { period.contains($0.date) }
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            header(period.title, detail: nil)
                            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 24) {
                                ForEach(items) { release in
                                    ReleaseTile(release: release, isUnheard: !yours.hasHeard(release))
                                }
                            }
                        }
                        .padding(.horizontal, PlayMetrics.margin)
                    }
                }

                if discovery.releasesState == .loading || discovery.releasesState == .idle, releases.isEmpty {
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 24) {
                        ForEach(0..<8, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.placeholderFill)
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .padding(.horizontal, PlayMetrics.margin)
                    .accessibilityHidden(true)
                }
            }
            .padding(.bottom, 24)
            .animation(.snappy, value: filter)
        }
        .overlay {
            if discovery.releasesState == .loaded || discovery.releasesState == .failed, releases.isEmpty {
                ContentUnavailableView(
                    discovery.releasesState == .failed ? "Couldn't Reach Apple Music" : "Nothing New Lately",
                    systemImage: discovery.releasesState == .failed ? "wifi.exclamationmark" : "calendar",
                    description: Text(discovery.releasesState == .failed
                        ? "Check your connection, then try again."
                        : filter == .all
                            ? "Your artists haven't put anything out in the last six months."
                            : "Nothing of this kind from your artists in the last six months.")
                )
            }
        }
        .navigationTitle("New from Your Artists")
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .principal) {
                filterPicker
                    .fixedSize()
            }
        }
        #else
        .toolbarTitleDisplayMode(.inline)
        #endif
        .task { await discovery.loadReleases() }
        .task(id: model.library.revision) {
            let history = model.library.history
            let found = await OffMainActor.run { YourReleases(history: history) }
            guard !Task.isCancelled else { return }
            yours = found
        }
        .refreshCommand()
        .refreshable { await discovery.loadReleases(force: true) }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func header(_ title: String, detail: LocalizedStringKey?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// As many as fit, filling the width, from the left.
    private static var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 160), spacing: PlayMetrics.shelfSpacing, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)]
        #endif
    }

    enum Period: CaseIterable, Identifiable {
        case thisWeek, thisMonth, earlier
        var id: Self { self }

        var title: String {
            switch self {
            case .thisWeek: String(localized: "This Week")
            case .thisMonth: String(localized: "This Month")
            case .earlier: String(localized: "Earlier")
            }
        }

        func contains(_ date: Date?) -> Bool {
            guard let date else { return self == .earlier }
            let age = Date.now.timeIntervalSince(date)
            switch self {
            case .thisWeek: return age < 7 * 86_400
            case .thisMonth: return age >= 7 * 86_400 && age < 31 * 86_400
            case .earlier: return age >= 31 * 86_400
            }
        }
    }
}

/// What the history knows about new releases: which albums you've heard some of, and how
/// often you play each artist.
nonisolated struct YourReleases: Sendable {
    private var albums: Set<String> = []
    private var artists: [String: Int] = [:]

    init() {}

    init(history: ListeningHistory) {
        for capture in history.captures {
            if let album = capture.albumIdentity { albums.insert(album) }
            for identity in capture.creditIdentities { artists[identity, default: 0] += 1 }
        }
    }

    func hasHeard(_ release: Discovery.Release) -> Bool {
        let title = StatsCalculator.folded(Self.plainTitle(release.album.title))
        return albums.contains { $0.hasPrefix(title + "\u{1F}") }
    }

    /// Plays of whoever made it: the first of its artists you play.
    func plays(of release: Discovery.Release) -> Int {
        let names = ArtistCredits.parse(artist: release.album.artistName).map(\.identity)
        return ([StatsCalculator.folded(release.album.artistName)] + names).lazy.compactMap { artists[$0] }.first ?? 0
    }

    /// The title as the history keeps it, without Apple Music's " - Single".
    private static func plainTitle(_ title: String) -> String {
        for suffix in [" - Single", " - EP"] where title.hasSuffix(suffix) {
            return String(title.dropLast(suffix.count))
        }
        return title
    }
}

/// The newest release, large, on a glow of its cover's colour: what it is, when it came out,
/// how much you play whoever made it, and Play.
private struct FeaturedRelease: View {
    let release: Discovery.Release
    let plays: Int
    let isHeard: Bool
    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openRoute
    @State private var glow: Color?
    @Environment(\.colorScheme) private var colorScheme

    private var cover: CoverArt {
        release.album.artwork.map(CoverArt.artwork) ?? .url(nil, seed: release.album.title)
    }

    var body: some View {
        let layout = Self.isStacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 18)) : AnyLayout(HStackLayout(alignment: .bottom, spacing: 28))
        layout {
            Button { openRoute(.album(release.album)) } label: {
                CoverImage(cover: cover, size: Self.side)
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(release.album.title)

            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Text(CollectionKind.of(release.album).title)
                    .font(.system(.largeTitle).weight(.bold))
                    .lineLimit(2)
                Text(release.album.artistName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                if let line = relationship {
                    Label(line, systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                HStack(spacing: 10) {
                    Button {
                        player.play(.album(release.album), from: PlayContext(kind: .album, title: release.album.title))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(minWidth: 74)
                    }
                    .buttonStyle(.glassProminent)
                    Button {
                        player.addToLibrary(release.album)
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    Menu {
                        GetWithLidarrButton(album: release.album.title, artist: release.album.artistName)
                        FeedItemMenu(item: FeedItem(album: release.album))
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .fixedSize()
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, PlayMetrics.margin)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            CoverGlow(color: glow, overscroll: 160)
                .padding(.bottom, -40)
        }
        .task(id: release.id) {
            guard let found = await CoverTint.glow(for: cover), !Task.isCancelled else { return }
            withAnimation(PlayMotion.tint) { glow = found }
        }
    }

    #if os(macOS)
    private static let side: CGFloat = 220
    private static let isStacked = false
    #else
    private static let side: CGFloat = 200
    private static let isStacked = true
    #endif

    /// "NEW ALBUM · SEPTEMBER 24".
    private var eyebrow: String {
        let kind = switch release.kind {
        case .album: String(localized: "New Album")
        case .ep: String(localized: "New EP")
        case .single: String(localized: "New Single")
        }
        guard let date = release.date else { return kind.uppercased() }
        let when = Calendar.current.isDateInToday(date) ? String(localized: "Out Today") : date.formatted(.dateTime.month(.wide).day())
        return "\(kind) · \(when)".uppercased()
    }

    /// Why it's here: how much you play them, and whether you've heard it yet.
    private var relationship: String? {
        guard plays > 0 else { return nil }
        let played = String(AttributedString(localized: "You've played them ^[\(plays) time](inflect: true)").characters)
        return isHeard ? String(localized: "\(played), and you've started this one") : played
    }
}

/// A release: its cover, name and artist, and what it is and when. Upcoming ones carry the
/// day they're out on the cover.
struct ReleaseTile: View {
    let release: Discovery.Release
    /// A fixed side on a shelf; nil fills the grid's column.
    var side: CGFloat?
    /// Nothing of it heard yet: a dot before the title, as Podcasts marks an episode.
    var isUnheard = false
    @State private var isHovered = false
    @Environment(PlayerModel.self) private var player

    var body: some View {
        NavigationLink(value: PlayRoute.album(release.album)) {
            VStack(alignment: .leading, spacing: 6) {
                cover
                    .overlay(alignment: .topLeading) {
                        if release.isUpcoming, let date = release.date {
                            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: .capsule)
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if isUnheard {
                            Circle()
                                .fill(.tint)
                                .frame(width: 7, height: 7)
                                .accessibilityLabel("New to You")
                        }
                        Text(CollectionKind.of(release.album).title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    Text(release.album.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(release.isUpcoming ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }
            .frame(width: side, alignment: .leading)
            .contentShape(.rect)
            .onHover { hovering in
                withAnimation(PlayMotion.hover) { isHovered = hovering }
            }
            .accessibilityElement(children: .combine)
            // Play shows only under the pointer, so VoiceOver has it as an action.
            .accessibilityActions {
                if !release.isUpcoming {
                    Button("Play", action: playAlbum)
                }
            }
        }
        .buttonStyle(.pressable)
        .contextMenu {
            GetWithLidarrButton(album: release.album.title, artist: release.album.artistName)
            if !release.isUpcoming {
                FeedItemMenu(item: FeedItem(album: release.album))
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        let art = release.album.artwork.map(CoverArt.artwork) ?? .url(nil, seed: release.album.title)
        Group {
            if let side {
                CoverImage(cover: art, size: side)
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in
                            CoverImage(cover: art, size: proxy.size.width)
                        }
                    }
            }
        }
        .shadow(color: .black.opacity(isHovered ? 0.25 : 0.12), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
        .overlay(alignment: .bottomTrailing) {
            if isHovered, !release.isUpcoming {
                Button(action: playAlbum) {
                    Label("Play \(release.album.title)", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.55), in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Play \(release.album.title)")
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
    }

    private func playAlbum() {
        player.play(.album(release.album), from: PlayContext(kind: .album, title: release.album.title))
    }

    /// "Single · Sep 20", or "Album · in 12 days" for one not out yet.
    private var detail: String {
        let kind = switch release.kind {
        case .album: String(localized: "Album")
        case .ep: String(localized: "EP")
        case .single: String(localized: "Single")
        }
        guard let date = release.date else { return kind }
        if release.isUpcoming {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: Calendar.current.startOfDay(for: date)).day ?? 0
            let when = days <= 1
                ? String(localized: "tomorrow")
                : String(AttributedString(localized: "in ^[\(days) day](inflect: true)").characters)
            return "\(kind) · \(when)"
        }
        return "\(kind) · \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

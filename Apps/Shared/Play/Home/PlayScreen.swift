import SwiftUI
import MusicKit
import TracksCore

/// The Play tab: start something in one tap, and have Tracks keep every song of it.
///
/// Music's Home, rebuilt around the history. The top is what you usually play at this hour;
/// below it, Apple Music's Recently Played, mixes made from your own listening, radio, your
/// library, and Apple's own picks.
struct PlayScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(PlayFeed.self) private var feed
    @AppStorage(PlayPreferences.layoutKey) private var storedLayout = ""
    @AppStorage(PlayPreferences.tracksRadioKey) private var isRadioOn = true
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true
    @AppStorage(NearbyDevices.storageKey) private var showsDevices = true
    @State private var showsSubscriptionOffer = false
    @State private var showsSettings = LaunchScene.opensPlaySettings
    @State private var showsEditor = LaunchScene.opensEditPlay

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                    // Access and subscription come first whatever the layout: nothing else
                    // on the page can play until they're sorted.
                    if let blocker {
                        statusCard(blocker)
                            .padding(.horizontal, PlayMetrics.margin)
                    }


                    ForEach(layout.visible) { section in
                        self.section(section)
                            .id(section.rawValue)
                    }

                    if feed.appleMusicState == .failed {
                        #if os(iOS)
                        Label("Couldn't reach Apple Music. Pull down to try again.", systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, PlayMetrics.margin)
                        #else
                        // No pull to refresh on the Mac.
                        HStack(spacing: 10) {
                            Label("Couldn't reach Apple Music.", systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Try Again") { Task { await reload() } }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, PlayMetrics.margin)
                        #endif
                    }

                    // Past everything else, suggestions for as long as you scroll, straight
                    // after Apple Music's picks. Edit Play is in Settings.
                    if blocker == nil {
                        KeepExploringSection(followsShelf: layout.isVisible(.suggestedSongs))
                            .id("keepExploring")
                    }
                }
                .padding(.top, Self.topPadding)
                .padding(.bottom, 24)
            }
            .onChange(of: feed.hasBuilt) {
                if let anchor = LaunchScene.scrollAnchor {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
        #if os(macOS)
        // No title over the page, and its glow meets the top edge until it scrolls under the bar.
        .headerUnderBar()
        #else
        .navigationTitle("Play")
        #endif
        #if os(iOS)
        // On the Mac, Settings is the app menu's.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if showsDevices { DevicesButton(opensAtLaunch: true) }
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        #endif
        .sheet(isPresented: $showsEditor) {
            PlayLayoutEditor()
        }
        .refreshCommand()
        .refreshable { await reload() }
        .task(id: model.musicAuthorization) {
            await feed.loadAppleMusic()
        }
        .task(id: DiscoverKey(artists: Set(feed.topArtists), authorization: model.musicAuthorization, allowsExplicit: allowsExplicit)) {
            await feed.loadFromYourArtists()
        }
        .onChange(of: allowsExplicit) {
            // Shelves already loaded hold the other versions. The shelves from your artists
            // reload through the task above, whose id includes the setting.
            Task { await feed.loadAppleMusic(force: true) }
        }
        .musicSubscriptionOffer(isPresented: $showsSubscriptionOffer, options: .init(messageIdentifier: .playMusic))
    }

    private var layout: PlayLayout { PlayLayout(stored: storedLayout) }

    private func reload() async {
        await feed.loadAppleMusic(force: true)
        await feed.loadFromYourArtists(force: true)
    }

    #if os(macOS)
    private static let topPadding: CGFloat = 20
    private static let hasSidebarLibrary = true
    #else
    private static let topPadding: CGFloat = 4
    private static let hasSidebarLibrary = false
    #endif

    // MARK: - Sections

    @ViewBuilder
    private func section(_ section: PlaySection) -> some View {
        switch section {
        case .suggestedSongs:
            if blocker == nil {
                // Tracks Radio leads the crate; with the crate hidden, it leads these instead.
                // Not while the crate is still coming, or Radio would show here and then leave.
                SuggestedSongsSection(includesRadio: !layout.isVisible(.forYou) || crateCards.isEmpty && !isCrateLoading)
            }
        case .suggestedArtists:
            if blocker == nil {
                SuggestedArtistsShelf()
            }
        case .forYou:
            forYou
        case .recentlyPlayed:
            if !feed.recentlyPlayed.isEmpty {
                Shelf(title: String(localized: "Recently Played"), items: feed.recentlyPlayed) { item in
                    FeedTile(item: item)
                }
            } else if feed.appleMusicState == .loading {
                PlaceholderShelf(title: String(localized: "Recently Played"))
            }
        case .mixes:
            mixesSection
        case .yourArtists:
            if !feed.favoriteArtists.isEmpty {
                Shelf(title: String(localized: "Your Artists"), items: feed.favoriteArtists) { artist in
                    FavoriteArtistTile(artist: artist)
                }
            }
        case .moods:
            MoodShelf()
        case .genres:
            GenreShelf()
        case .newReleases:
            if !feed.newReleases.isEmpty {
                Shelf(title: String(localized: "New from Your Artists"), items: feed.newReleases) {
                    NavigationLink(String(localized: "See All"), value: PlayRoute.newReleases)
                } tile: { item in
                    FeedTile(item: item)
                }
            }
        case .charts:
            if !feed.charts.isEmpty {
                Shelf(title: String(localized: "Top Charts"), items: feed.charts) { item in
                    FeedTile(item: item)
                }
            }
        case .radio:
            if !radio.isEmpty {
                Shelf(title: String(localized: "Radio"), items: radio) { item in
                    FeedTile(item: item)
                }
            } else if feed.appleMusicState == .loading {
                PlaceholderShelf(title: String(localized: "Radio"))
            }
        case .library:
            // The Mac's library is in the sidebar.
            #if os(iOS)
            if showsLibrary, !Self.hasSidebarLibrary {
                LibraryOverview()
                    .padding(.horizontal, PlayMetrics.margin)
            }
            #endif
        case .appleMusic:
            ForEach(feed.recommendations.prefix(PlayFeed.pickRows)) { recommendation in
                Shelf(title: recommendation.title, items: recommendation.items) { item in
                    FeedTile(item: item)
                }
            }
        }
    }

    // MARK: - For You

    /// What stands in the way of playing anything, if something does.
    private enum Blocker { case access, subscription }

    private var blocker: Blocker? {
        if !model.isShowingSampleData, model.musicAuthorization != .authorized { return .access }
        if feed.cannotPlayCatalog { return .subscription }
        return nil
    }

    @ViewBuilder
    private func statusCard(_ blocker: Blocker) -> some View {
        switch blocker {
        case .access:
            PlayAccessCard()
        case .subscription:
            PlayStateCard(
                symbol: "music.note",
                title: String(localized: "Playing Needs Apple Music"),
                message: String(localized: "Tracks plays songs from Apple Music and keeps every one you hear. Your history and stats work without it.")
            ) {
                if feed.subscription?.canBecomeSubscriber == true {
                    Button("Try Apple Music") { showsSubscriptionOffer = true }
                        .buttonStyle(.glassProminent)
                }
            }
        }
    }

    @ViewBuilder
    private var forYou: some View {
        let cards = crateCards
        if blocker != nil {
            // Nothing to offer until it can play.
        } else if !cards.isEmpty {
            // Tracks Radio in front when there's enough history for it, this hour's mix beside it.
            ForYouCrate(cards: cards, leadID: cards.contains { $0.id == "station" } ? "station" : leadMix?.id)
        } else if let station = feed.liveStations.first {
            StationHero(item: station)
                .padding(.horizontal, PlayMetrics.margin)
        } else if feed.hasBuilt, model.library.isLoaded, feed.appleMusicState != .loading {
            PlayStateCard(
                symbol: "play.circle",
                title: String(localized: "Play Something"),
                message: String(localized: "Search for a song, or open your library. Tracks keeps every song you play here, and makes mixes from them as you listen.")
            ) {
                Button("Search Apple Music") { model.beginSearch(in: .appleMusic) }
                    .buttonStyle(.glassProminent)
            }
            .padding(.horizontal, PlayMetrics.margin)
        } else {
            CratePlaceholder()
        }
    }

    /// Whether For You is still waiting on the history or Apple Music to show its crate.
    private var isCrateLoading: Bool {
        feed.liveStations.isEmpty && !(feed.hasBuilt && model.library.isLoaded && feed.appleMusicState != .loading)
    }

    /// The crate: Tracks Radio in the middle, starting in front, with this hour's mix, Discover
    /// and the rest of the day's mixes either side of it.
    private var crateCards: [ForYouCard] {
        var cards: [ForYouCard] = []
        if let lead = leadMix { cards.append(.mix(lead)) }
        if !feed.discover.isEmpty { cards.append(.discover(feed.discover)) }
        cards += feed.mixes.otherTimes.map(ForYouCard.mix)
        if isRadioOn, hasHistoryForRadio { cards.insert(.station, at: cards.count / 2) }
        return cards
    }

    /// This hour's mix, or the first mix there is when this hour has no habit yet.
    private var leadMix: Mix? {
        feed.mixes.rightNow ?? feed.mixes.mixes.first
    }

    /// Whether there's enough history for Tracks Radio to be worth playing.
    private var hasHistoryForRadio: Bool {
        !feed.mixes.all.isEmpty && model.library.history.captures.count >= 20
    }

    // MARK: - Mixes

    @ViewBuilder
    private var mixesSection: some View {
        // The mix leading For You isn't repeated here, unless For You is hidden.
        let leading = layout.isVisible(.forYou) && feed.mixes.rightNow == nil ? leadMix?.id : nil
        let shelf = feed.mixes.mixes.filter { $0.id != leading }
        if !shelf.isEmpty {
            Shelf(title: String(localized: "Made from Your Listening"), items: shelf) { mix in
                MixTile(mix: mix)
            }
        } else if feed.hasBuilt, model.library.isLoaded, !model.library.history.isEmpty, leadMix == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Made from Your Listening")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Mixes appear as you listen: songs on repeat, radio finds, and old favorites to come back to.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, PlayMetrics.margin)
        }
    }

    /// Apple's live stations only. Personal stations from the history still play from Recently Played.
    private var radio: [FeedItem] { feed.liveStations }

    private var showsLibrary: Bool {
        !model.isShowingSampleData && model.musicAuthorization == .authorized
    }
}

/// What Discover is looked up from. A change to any of it looks again.
private struct DiscoverKey: Equatable {
    /// A set: top artists trading places isn't a reason to look again.
    let artists: Set<String>
    let authorization: MusicAuthorization.Status
    let allowsExplicit: Bool
}

/// A live station, when there's no history to make a mix from yet.
struct StationHero: View {
    let item: FeedItem
    @Environment(PlayerModel.self) private var player
    @State private var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CoverImage(cover: item.cover, size: 132)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("Live Radio")
                    .textCase(.uppercase)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(item.title)
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("Start here. Every song you hear is kept, with its station.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let (request, context) = item.stationRequest { player.play(request, from: context) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(tint ?? .black)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 50)
                    .background(.white, in: .capsule)
            }
            .buttonStyle(.pressable)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill((tint ?? Color(red: 0.2, green: 0.05, blue: 0.08)).gradient)
        }
        .onAppear {
            if tint == nil, case .artwork(let artwork) = item.cover, let color = artwork.backgroundColor {
                tint = CoverTint.color(from: color)
            }
        }
    }
}

/// Asks for Apple Music access, in place, saying what it's for.
struct PlayAccessCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false

    var body: some View {
        PlayStateCard(
            symbol: model.musicAuthorization == .notDetermined ? "play.circle" : "exclamationmark.triangle.fill",
            title: model.musicAuthorization == .notDetermined
                ? String(localized: "Play Apple Music in Tracks")
                : String(localized: "Apple Music Access Is Off"),
            message: model.musicAuthorization == .notDetermined
                ? String(localized: "Play your library, radio and mixes made from your listening. Tracks keeps every song you hear, even in the background.")
                : String(localized: "Turn on Media & Apple Music for Tracks in Settings to play music here.")
        ) {
            if model.musicAuthorization == .notDetermined {
                Button("Allow Apple Music Access") {
                    isRequesting = true
                    Task {
                        await model.requestMusicAccess()
                        isRequesting = false
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isRequesting)
            } else {
                Button("Open Settings") {
                    if let url = SystemSettingsLink.musicAccess { openURL(url) }
                }
                .buttonStyle(.glass)
            }
        }
        .onAppear(perform: model.refreshMusicAuthorization)
    }
}

/// A card for a state the page is in rather than for content: no access, no subscription.
struct PlayStateCard<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// A shelf's shape while Apple Music answers.
private struct PlaceholderShelf: View {
    let title: String
    @ScaledMetric(relativeTo: .subheadline) private var side = PlayMetrics.tile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, PlayMetrics.margin)
            // In a scroll view like a real shelf's. A plain row of three tiles is wider than
            // the screen and can't shrink, so it pushed the whole page wider until it loaded.
            ScrollView(.horizontal) {
                HStack(spacing: PlayMetrics.shelfSpacing) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: CoverImage.radius(for: min(side, 220)), style: .continuous)
                                .fill(Color(.secondarySystemFill))
                                .frame(width: min(side, 220), height: min(side, 220))
                            Capsule().fill(Color(.secondarySystemFill)).frame(width: 110, height: 10)
                            Capsule().fill(Color(.tertiarySystemFill)).frame(width: 70, height: 10)
                        }
                    }
                }
            }
            .contentMargins(.horizontal, PlayMetrics.margin, for: .scrollContent)
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Loading \(title)"))
    }
}

/// A row that darkens under a finger, as list rows do.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(.systemFill) : .clear)
    }
}

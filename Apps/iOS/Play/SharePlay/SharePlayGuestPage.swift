import SwiftUI
import MusicKit
import TracksCore

extension View {
    /// Opens the SharePlay page when this iPhone joins someone else's SharePlay, over whatever
    /// is on screen, and asks before a scanned code ends this iPhone's own. Now Playing closes
    /// first: a sheet or an alert can't show from under a full-screen cover.
    func sharePlayGuestPage(closing showsNowPlaying: Binding<Bool>) -> some View {
        modifier(SharePlayPresenter(showsNowPlaying: showsNowPlaying))
    }
}

private struct SharePlayPresenter: ViewModifier {
    @Binding var showsNowPlaying: Bool
    @State private var isPresented = false
    @State private var asksToEnd = false
    private var sharePlay = SharePlayController.shared

    init(showsNowPlaying: Binding<Bool>) {
        _showsNowPlaying = showsNowPlaying
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: pageClosed) {
                SharePlayGuestPage()
            }
            .onChange(of: sharePlay.showsGuestPage, initial: true) { _, shows in
                guard shows else {
                    isPresented = false
                    return
                }
                guard showsNowPlaying else {
                    isPresented = true
                    return
                }
                showsNowPlaying = false
                Task {
                    // Once the cover has gone.
                    try? await Task.sleep(for: .milliseconds(500))
                    isPresented = sharePlay.showsGuestPage
                }
            }
            .onChange(of: sharePlay.pendingInvite) { _, invite in
                guard invite != nil else { return }
                guard showsNowPlaying else {
                    asksToEnd = true
                    return
                }
                showsNowPlaying = false
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard sharePlay.pendingInvite != nil else { return }
                    // Closing Now Playing closed the code with it, and with no one joined,
                    // SharePlay went too: nothing left to ask about.
                    if sharePlay.role == .host {
                        asksToEnd = true
                    } else {
                        sharePlay.endHostingAndJoin()
                    }
                }
            }
            .alert("End Your SharePlay?", isPresented: $asksToEnd) {
                Button("End and Join", role: .destructive, action: sharePlay.endHostingAndJoin)
                Button("Cancel", role: .cancel) { sharePlay.pendingInvite = nil }
            } message: {
                Text(joinMessage)
            }
    }

    private var joinMessage: String {
        switch sharePlay.guestCount {
        case 0: String(localized: "To add songs to someone else's music, this iPhone stops sharing its own.")
        case 1: String(localized: "The person adding songs to your music will be disconnected.")
        case let count: String(localized: "The \(count) people adding songs to your music will be disconnected.")
        }
    }

    /// The page went away without Leave or Close: something else took the screen, or it was
    /// swiped away once SharePlay had ended. Either way, nothing is left half joined.
    private func pageClosed() {
        guard sharePlay.showsGuestPage else { return }
        if sharePlay.guest.phase == .ended {
            sharePlay.closeEnded()
        } else {
            sharePlay.leave()
        }
    }
}

/// Someone else's SharePlay, from a passenger's seat: what's playing on their iPhone, what's
/// coming up, and Apple Music to pick songs from. What's playing here is left alone.
///
/// The host's song glows at the top of the page in its cover's colour, as a collection's page
/// does, so it's plain whose music this is before anything is read.
struct SharePlayGuestPage: View {
    @Environment(AppModel.self) private var model
    @State private var query = LaunchScene.sharePlaySearch ?? ""
    @State private var results: [SharePlaySong] = []
    @State private var searchState: SearchState = .idle
    @State private var glow: Color?
    @Environment(\.openURL) private var openURL
    private var sharePlay = SharePlayController.shared

    enum SearchState: Equatable { case idle, loading, loaded, failed }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("SharePlay")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Once it has ended, Close is on the page itself.
                    if sharePlay.guest.phase != .ended {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Leave", action: sharePlay.leave)
                        }
                    }
                }
                .navigationDestination(for: UpNextPage.self) { _ in
                    SharePlayUpNextPage()
                }
                .navigationDestination(for: SharePlayLibraryPage.self) { page in
                    SharePlayLibraryPageView(page: page)
                }
        }
        // In a moving car, a stray swipe mustn't leave. Leave is in the toolbar, and once
        // SharePlay has ended the page closes any way it likes.
        .interactiveDismissDisabled(sharePlay.guest.phase != .ended)
        .sensoryFeedback(.impact(weight: .light), trigger: addedCount)
        .task(id: SearchKey(query: query, authorization: authorization, allowsExplicit: snapshot?.allowsExplicit ?? true)) {
            await runSearch()
        }
        .onAppear(perform: model.refreshMusicAuthorization)
    }

    @ViewBuilder
    private var content: some View {
        switch sharePlay.guest.phase {
        case .joining where sharePlay.guestNeedsLocalNetwork:
            ContentUnavailableView {
                Label("Allow Local Network", systemImage: "network")
            } description: {
                Text("Tracks connects straight to the iPhone that's playing. Turn on Local Network for Tracks in Settings to join.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            }
        case .joining:
            ContentUnavailableView {
                Label("Joining SharePlay", systemImage: "shareplay")
            } description: {
                Text(joiningLine)
            } actions: {
                ProgressView()
            }
        case .ended:
            ContentUnavailableView {
                Label("SharePlay Ended", systemImage: "shareplay.slash")
            } description: {
                Text("Songs you added stay in their Up Next.")
            } actions: {
                Button("Close") { sharePlay.closeEnded() }
                    .buttonStyle(.borderedProminent)
            }
        case .joined:
            joined
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Apple Music")
        }
    }

    // MARK: - Joined

    private var snapshot: SharePlaySnapshot? { sharePlay.guest.snapshot }

    /// What's happening while it joins, by how it's joining.
    private var joiningLine: LocalizedStringKey {
        switch (sharePlay.guestConnection, sharePlay.isSlowToConnect) {
        case (.sharePlay, false): "Connecting to the iPhone that's playing."
        case (.sharePlay, true): "Still connecting. Check that both iPhones are online."
        case (.code, false): "Looking for the iPhone that's playing."
        case (.code, true): "Still looking. Keep Wi-Fi on, and stay close to the iPhone that's playing."
        }
    }

    @ViewBuilder
    private var joined: some View {
        if isSearching {
            searchResults
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PlayMetrics.sectionSpacing) {
                    SharePlayHostCard(track: snapshot?.nowPlaying, isPlaying: snapshot?.isPlaying == true)
                    if sharePlay.isReconnecting {
                        SharePlayNotice(text: "Reconnecting to their iPhone. Stay close to it to keep adding songs.", systemImage: "wifi.exclamationmark")
                    }
                    if let notice {
                        SharePlayNotice(text: notice.text, systemImage: notice.symbol)
                    }
                    if authorization != .authorized {
                        accessCard
                    }
                    upNext
                    if authorization == .authorized {
                        SharePlayLibraryLinks()
                    }
                }
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(alignment: .top) {
                CoverGlow(color: glow)
            }
            .task(id: snapshot?.nowPlaying?.identity) {
                guard let track = snapshot?.nowPlaying,
                      let found = await CoverTint.glow(for: .url(track.artworkURL, seed: track.title)),
                      !Task.isCancelled
                else { return }
                withAnimation(PlayMotion.tint) { glow = found }
            }
        }
    }

    /// What's different about adding here, when anything is.
    private var notice: (text: LocalizedStringKey, symbol: String)? {
        guard let snapshot else { return nil }
        if snapshot.isStation {
            return ("A station is playing on their iPhone, so there's no queue to add to. You can add songs once they play something else.", "dot.radiowaves.left.and.right")
        }
        if snapshot.source == .yourMusic {
            return ("Their iPhone is playing its own music, so it adds the songs it has.", "music.note.house")
        }
        return nil
    }

    @ViewBuilder
    private var upNext: some View {
        if let snapshot, !snapshot.isStation {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    SearchSectionTitle("Up Next")
                    Spacer()
                    if snapshot.upNext.count > 5 {
                        NavigationLink("See All", value: UpNextPage())
                            .font(.body)
                    }
                }
                if snapshot.upNext.isEmpty {
                    Text("Nothing's queued after this song. Search for one to play next.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    ForEach(snapshot.upNext.prefix(5)) { track in
                        SharePlayQueueRow(track: track)
                    }
                }
            }
        }
    }

    // MARK: - Apple Music access

    private var authorization: MusicAuthorization.Status {
        #if DEBUG
        if sharePlay.demo?.deniesAccess == true { return .notDetermined }
        if model.isShowingSampleData { return .authorized }
        #endif
        return model.musicAuthorization
    }

    private var accessCard: some View {
        SharePlayAccessCard(authorization: authorization)
    }

    // MARK: - Searching

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var searchResults: some View {
        if authorization != .authorized {
            ScrollView {
                accessCard
                    .padding(.horizontal, PlayMetrics.margin)
                    .padding(.top, 16)
            }
        } else if searchState == .failed {
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await runSearch() } }
            }
        } else if results.isEmpty, searchState == .loaded {
            ContentUnavailableView.search(text: query)
        } else if results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let notice, snapshot?.isStation == true {
                        SharePlayNotice(text: notice.text, systemImage: notice.symbol)
                            .padding(.bottom, 10)
                    }
                    SearchSectionTitle("Songs")
                    LazyVStack(spacing: 0) {
                        ForEach(results, id: \.catalogID) { song in
                            SharePlayResultRow(song: song)
                        }
                    }
                }
                .padding(.horizontal, PlayMetrics.margin)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, authorization == .authorized else {
            results = []
            searchState = .idle
            return
        }
        // A short pause so typing doesn't search on every letter.
        try? await Task.sleep(for: .milliseconds(280))
        guard !Task.isCancelled else { return }
        searchState = .loading
        #if DEBUG
        if let demo = sharePlay.demo {
            guard !demo.isOffline else {
                searchState = .failed
                return
            }
            results = demo.search(term)
            searchState = .loaded
            return
        }
        #endif
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 25
            let response = try await request.response()
            guard !Task.isCancelled else { return }
            // One version of each song, the clean one where explicit songs are off there.
            let songs = PlayPreferences.versions(of: Array(response.songs), allowsExplicit: snapshot?.allowsExplicit ?? true)
            results = songs.map(SharePlaySong.init)
            searchState = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            searchState = .failed
        }
    }

    /// Songs that made it in, for the haptic that says so. Only this person's picks change it.
    private var addedCount: Int {
        sharePlay.guest.adds.values.count { if case .added = $0 { true } else { false } }
    }

    private struct SearchKey: Equatable {
        let query: String
        let authorization: MusicAuthorization.Status
        let allowsExplicit: Bool
    }

    struct UpNextPage: Hashable {}
}

extension SharePlaySong {
    init(_ song: Song) {
        self.init(
            catalogID: song.id.rawValue,
            title: song.title,
            artistName: song.artistName,
            albumTitle: song.albumTitle,
            artworkURL: song.artwork?.url(width: 300, height: 300)?.absoluteString,
            isExplicit: song.isExplicit
        )
    }
}

// MARK: - Parts

/// What's playing on the host's iPhone: its cover, the song, and whether it's playing.
private struct SharePlayHostCard: View {
    let track: SharePlayTrack?
    let isPlaying: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var coverSide: CGFloat = 76

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? String(localized: "Nothing Playing"))
                    .font(.title3.bold())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let track {
                    Text(track.artistName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                }
                Label {
                    Text(track == nil ? "Waiting for their iPhone to play" : isPlaying ? "Playing on Their iPhone" : "Paused on Their iPhone")
                } icon: {
                    Image(systemName: isPlaying ? "waveform" : "pause.fill")
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isPlaying && !reduceMotion)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var cover: some View {
        let side = min(coverSide, 120)
        if let track {
            CoverImage(cover: .url(track.artworkURL, seed: track.title), size: side)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        } else {
            RoundedRectangle(cornerRadius: CoverImage.radius(for: side), style: .continuous)
                .fill(.fill.tertiary)
                .frame(width: side, height: side)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }
}

/// Searching needs Apple Music access: asked for from here, where it's plain what it's for,
/// or the way to turn it back on. No subscription is needed to search.
private struct SharePlayAccessCard: View {
    let authorization: MusicAuthorization.Status
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add From Apple Music", systemImage: "music.note")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch authorization {
            case .notDetermined:
                Button("Allow Apple Music Access", action: requestAccess)
                    .buttonStyle(.borderedProminent)
                    .disabled(isRequesting || model.isShowingSampleData)
                    .padding(.top, 4)
            case .denied:
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            default:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
    }

    private var message: LocalizedStringKey {
        switch authorization {
        case .notDetermined: "Allow Tracks to use Apple Music to search for songs to add, and to pick them from your library and playlists. You don't need a subscription to search."
        case .restricted: "Screen Time or a device profile doesn't allow Apple Music access, so you can't search here."
        default: "To find songs to add, turn on Media & Apple Music for Tracks in Settings."
        }
    }

    private func requestAccess() {
        isRequesting = true
        Task {
            await model.requestMusicAccess()
            isRequesting = false
        }
    }

    private func openSettings() {
        if let url = SystemSettingsLink.musicAccess { openURL(url) }
    }
}

/// A short note about how adding works here, beside a symbol.
struct SharePlayNotice: View {
    let text: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// A song in the host's Up Next.
private struct SharePlayQueueRow: View {
    let track: SharePlayTrack

    var body: some View {
        HStack(spacing: 8) {
            TrackRow(title: track.title, subtitle: track.artistName, cover: .url(track.artworkURL, seed: track.title))
            if track.isFromSharePlay {
                Image(systemName: "shareplay")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Added by SharePlay")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A song found in Apple Music, to add to the host's queue: a tap adds it to the end, and
/// its menu can play it next instead.
struct SharePlayResultRow: View {
    let song: SharePlaySong
    private var sharePlay = SharePlayController.shared

    init(song: SharePlaySong) {
        self.song = song
    }

    private var state: SharePlayGuest.AddState? { sharePlay.guest.state(of: song.catalogID) }
    /// Nothing can reach their iPhone while it's reconnecting.
    private var canAdd: Bool { sharePlay.guest.snapshot?.acceptsSongs == true && !sharePlay.isReconnecting }

    var body: some View {
        Button {
            sharePlay.add(song, placement: .last)
        } label: {
            HStack(spacing: 8) {
                TrackRow(
                    title: song.title,
                    subtitle: subtitle,
                    cover: .url(song.artworkURL, seed: song.title),
                    isExplicit: song.isExplicit,
                    isPlayable: canAdd
                )
                SharePlayAddGlyph(state: state, canAdd: canAdd)
            }
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canAdd || state == .sending || state?.isDone == true)
        .contextMenu {
            if canAdd, state?.isDone != true {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    sharePlay.add(song, placement: .next)
                }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    sharePlay.add(song, placement: .last)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(song.title), \(song.artistName)"))
        .accessibilityValue(Text(stateLine ?? ""))
        .accessibilityHint(canAdd && state?.isDone != true ? Text("Adds it to the end of their Up Next") : Text(""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play Next") { sharePlay.add(song, placement: .next) }
    }

    /// The artist and album, or, once it's been tried, what became of it.
    private var subtitle: String {
        stateLine ?? [song.artistName, song.albumTitle].compactMap(\.self).joined(separator: " · ")
    }

    private var stateLine: String? {
        switch state {
        case nil: nil
        case .sending: String(localized: "Adding…")
        case .added(.next): String(localized: "Playing Next")
        case .added(.last): String(localized: "Added to Up Next")
        case .notAdded(let refusal): Self.reason(refusal, yourMusic: sharePlay.guest.snapshot?.source == .yourMusic)
        }
    }

    static func reason(_ refusal: SharePlayRefusal, yourMusic: Bool) -> String {
        switch refusal {
        case .alreadyQueued: String(localized: "Already in Up Next")
        case .station: String(localized: "Not added: a station is playing")
        case .notFound: yourMusic ? String(localized: "Not added: it's not in their music") : String(localized: "Not added: Apple Music can't play it there")
        case .explicit: String(localized: "Not added: explicit songs are off there")
        case .tooMany: String(localized: "Not added: too many at once, try again soon")
        case .unavailable: String(localized: "Not added: try again in a moment")
        case .noAnswer: String(localized: "Not added: no answer from their iPhone")
        }
    }
}

/// Add, then a spinner while it goes, then a check once it's in.
private struct SharePlayAddGlyph: View {
    let state: SharePlayGuest.AddState?
    let canAdd: Bool

    var body: some View {
        Group {
            switch state {
            case .sending:
                ProgressView()
            case .added, .notAdded(.alreadyQueued):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            case .notAdded:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            case nil:
                Image(systemName: "plus.circle")
                    .foregroundStyle(canAdd ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
        }
        .font(.title2)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// All of their Up Next that’s been sent, from "See All".
private struct SharePlayUpNextPage: View {
    private var sharePlay = SharePlayController.shared

    var body: some View {
        let snapshot = sharePlay.guest.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(snapshot?.upNext ?? []) { track in
                    SharePlayQueueRow(track: track)
                }
                if let snapshot, snapshot.upNextCount > snapshot.upNext.count {
                    Text("and \(snapshot.upNextCount - snapshot.upNext.count) more")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, PlayMetrics.margin)
            .padding(.vertical, 12)
        }
        .navigationTitle("Up Next")
        .navigationBarTitleDisplayMode(.inline)
    }
}

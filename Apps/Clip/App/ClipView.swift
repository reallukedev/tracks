import SwiftUI
import StoreKit
import CoreImage
import TracksCore

/// The App Clip's one screen: what's playing on the host's iPhone, what's coming up, and a
/// search to add songs, laid out as Tracks’ own SharePlay page is for a passenger with Tracks.
struct ClipView: View {
    @Bindable var model: ClipModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("SharePlay")
                .navigationBarTitleDisplayMode(.inline)
        }
        .sensoryFeedback(.impact(weight: .light), trigger: addedCount)
        // Once it's over, a natural pause: Tracks itself, offered once, at the bottom.
        .appStoreOverlay(isPresented: $model.offersTracks) {
            SKOverlay.AppClipConfiguration(position: .bottom)
        }
        .onChange(of: model.session?.guest.phase) { _, phase in
            if phase == .ended { model.offersTracks = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = model.session, !model.hasNoCode {
            switch session.guest.phase {
            case .joining:
                ContentUnavailableView {
                    Label("Joining SharePlay", systemImage: "shareplay")
                } description: {
                    Text(session.isSlowToConnect
                        ? "Still connecting. Check that you're online, and that the iPhone that's playing is too."
                        : "Connecting to the iPhone that's playing.")
                } actions: {
                    ProgressView()
                }
            case .ended:
                ContentUnavailableView {
                    Label("SharePlay Ended", systemImage: "shareplay.slash")
                } description: {
                    Text("Songs you added stay in their Up Next.")
                } actions: {
                    Button("Get Tracks") { model.offersTracks = true }
                        .buttonStyle(.borderedProminent)
                }
            case .joined:
                ClipJoinedView(model: model, session: session)
            }
        } else {
            ContentUnavailableView {
                Label("Scan a SharePlay Code", systemImage: "qrcode.viewfinder")
            } description: {
                Text("Open the Camera and point it at the code on the car's screen, or on the iPhone that's playing.")
            }
        }
    }

    /// Songs that made it in, for the haptic that says so. Only this person's picks change it.
    private var addedCount: Int {
        model.session?.guest.adds.values.count { if case .added = $0 { true } else { false } } ?? 0
    }
}

/// Joined: the host's song, then its Up Next, or the search.
private struct ClipJoinedView: View {
    @Bindable var model: ClipModel
    let session: SharePlayCodeGuest
    @State private var glow: Color?

    private var snapshot: SharePlaySnapshot? { session.guest.snapshot }
    private var isSearching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Group {
            if isSearching {
                results
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ClipHostCard(track: snapshot?.nowPlaying, isPlaying: snapshot?.isPlaying == true)
                        if session.isReconnecting {
                            ClipNotice(text: "Reconnecting to their iPhone.", systemImage: "wifi.exclamationmark")
                        }
                        if let notice {
                            ClipNotice(text: notice.text, systemImage: notice.symbol)
                        }
                        upNext
                        ClipLibraryCard { model.offersTracks = true }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
                // The host's song glows at the top in its cover's colour, as Tracks’ page has
                // it, so it's plain whose music this is before anything is read.
                .background(alignment: .top) { ClipGlow(color: glow) }
                .task(id: snapshot?.nowPlaying?.artworkURL) {
                    guard let found = await ClipGlow.color(of: snapshot?.nowPlaying?.artworkURL), !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.4)) { glow = found }
                }
            }
        }
        .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Apple Music")
        .task(id: SearchKey(query: model.query, allowsExplicit: snapshot?.allowsExplicit ?? true)) {
            await model.search()
        }
    }

    private struct SearchKey: Equatable {
        let query: String
        let allowsExplicit: Bool
    }

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
                Text("Up Next")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                if snapshot.upNext.isEmpty {
                    Text("Nothing's queued after this song. Search for one to play next.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    ForEach(snapshot.upNext) { track in
                        ClipSongRow(title: track.title, subtitle: track.artistName, artworkURL: track.artworkURL) {
                            if track.isFromSharePlay {
                                Image(systemName: "shareplay")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Added by SharePlay")
                            }
                        }
                    }
                    if snapshot.upNextCount > snapshot.upNext.count {
                        Text("and \(snapshot.upNextCount - snapshot.upNext.count) more")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.searchState == .failed {
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.search() } }
            }
        } else if model.results.isEmpty, model.searchState == .loaded {
            ContentUnavailableView.search(text: model.query)
        } else if model.results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let notice, snapshot?.isStation == true {
                        ClipNotice(text: notice.text, systemImage: notice.symbol)
                            .padding(.bottom, 10)
                    }
                    Text("Songs")
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(spacing: 0) {
                        ForEach(model.results, id: \.catalogID) { song in
                            ClipResultRow(model: model, session: session, song: song)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.immediately)
        }
    }
}

/// What's playing on the host's iPhone: its cover, the song, and whether it's playing.
private struct ClipHostCard: View {
    let track: SharePlayTrack?
    let isPlaying: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        layout {
            ClipCover(url: track?.artworkURL, side: 76)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? String(localized: "Nothing Playing"))
                    .font(.title3.bold())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if let track {
                    Text(track.artistName)
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
}

/// A song found in Apple Music: a tap adds it to the end of their Up Next, and its menu can
/// play it next instead.
private struct ClipResultRow: View {
    let model: ClipModel
    let session: SharePlayCodeGuest
    let song: SharePlaySong

    private var state: SharePlayGuest.AddState? { session.guest.state(of: song.catalogID) }
    private var canAdd: Bool { session.guest.snapshot?.acceptsSongs == true && !session.isReconnecting }

    var body: some View {
        Button {
            model.add(song, placement: .last)
        } label: {
            ClipSongRow(title: song.title, subtitle: subtitle, artworkURL: song.artworkURL, isExplicit: song.isExplicit, isDimmed: !canAdd) {
                ClipAddGlyph(state: state, canAdd: canAdd)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!canAdd || state == .sending || state?.isDone == true)
        .contextMenu {
            if canAdd, state?.isDone != true {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.add(song, placement: .next) }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { model.add(song, placement: .last) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(song.title), \(song.artistName)"))
        .accessibilityValue(Text(stateLine ?? ""))
        .accessibilityHint(canAdd && state?.isDone != true ? Text("Adds it to the end of their Up Next") : Text(""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Play Next") { model.add(song, placement: .next) }
    }

    private var subtitle: String {
        stateLine ?? [song.artistName, song.albumTitle].compactMap(\.self).joined(separator: " · ")
    }

    private var stateLine: String? {
        switch state {
        case nil: nil
        case .sending: String(localized: "Adding…")
        case .added(.next): String(localized: "Playing Next")
        case .added(.last): String(localized: "Added to Up Next")
        case .notAdded(let refusal): Self.reason(refusal, yourMusic: session.guest.snapshot?.source == .yourMusic)
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

/// A song's row: its cover, its name, and what's beside it.
private struct ClipSongRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    let artworkURL: String?
    var isExplicit = false
    var isDimmed = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            ClipCover(url: artworkURL, side: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .lineLimit(1)
                    if isExplicit {
                        Image(systemName: "e.square.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Explicit")
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .opacity(isDimmed ? 0.5 : 1)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// Add, then a spinner while it goes, then a check once it's in.
private struct ClipAddGlyph: View {
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

/// A cover from Apple Music, or a quiet tile while there's none.
private struct ClipCover: View {
    let url: String?
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(12, max(4, side * 0.12)), style: .continuous)
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                shape.fill(.fill.tertiary)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.36))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .accessibilityHidden(true)
    }
}

/// Where Tracks’ Your Library would be: what the App Clip can't do, since Apple keeps Apple
/// Music accounts from App Clips, and Tracks, which can. Quiet, and at the end, as the HIG
/// asks of an App Clip suggesting its app.
private struct ClipLibraryCard: View {
    let getTracks: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Add From Your Library", systemImage: "music.note.list")
                .font(.headline)
            Text("With Tracks, you can also pick songs from your Apple Music library and playlists.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Get Tracks", action: getTracks)
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// A cover's colour behind the top of the page, strongest at the top and gone before the
/// songs.
private struct ClipGlow: View {
    let color: Color?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tint = color ?? .clear
        LinearGradient(
            stops: [
                .init(color: tint.opacity(colorScheme == .dark ? 0.5 : 0.34), location: 0),
                .init(color: tint.opacity(colorScheme == .dark ? 0.2 : 0.12), location: 0.6),
                .init(color: tint.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 420)
        .padding(.top, -120)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The average of a cover, a little more saturated than it comes out, which is greyer
    /// than the cover looks. Nil without a cover.
    static func color(of address: String?) async -> Color? {
        guard let address, let url = URL(string: address),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let image = CIImage(data: data)
        else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])
        guard let output = filter?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let rgb = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(1, saturation * 1.3), brightness: max(0.35, brightness))
    }
}

/// A short note about how adding works right now, beside a symbol.
private struct ClipNotice: View {
    let text: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

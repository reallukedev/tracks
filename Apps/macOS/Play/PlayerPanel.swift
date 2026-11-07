import SwiftUI
import TracksCore

/// Which page the player's panel shows.
enum PlayerPanelPage: String, CaseIterable, Identifiable {
    case upNext, history

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .upNext: "Up Next"
        case .history: "Your History"
        }
    }
}

/// Rising from the bar, as iTunes's Up Next did: what's coming, or the playing song's
/// history. Opened from the bar, the Controls menu, or ⌥⌘U and ⌥⌘Y.
struct PlayerPanel: View {
    @Binding var page: PlayerPanelPage

    static let width: CGFloat = 380

    @Environment(PlayerModel.self) private var player
    @Environment(\.openPlayRoute) private var openPlayRoute

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $page) {
                ForEach(PlayerPanelPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let track = player.current {
                switch page {
                case .upNext:
                    UpNextList()
                case .history:
                    ScrollView {
                        LinerNotes(track: track) {
                            openPlayRoute(.stats(.song(track.songIdentity)))
                        }
                        .padding(20)
                    }
                }
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// What's playing and what's queued after it. Drag to reorder, Delete to remove, double-click
/// or Return to play a song now.
struct UpNextList: View {
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @AppStorage(PlayPreferences.autoplayKey) private var autoplay = true
    @State private var selection: Set<String> = []
    @State private var isDropTarget = false
    @Environment(\.openRadioTuner) private var openRadioTuner

    var body: some View {
        List(selection: $selection) {
            Section {
                if let track = player.current {
                    NowRow(track: track)
                        .selectionDisabled()
                }
            } header: {
                if player.isOnAutoplayPick {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Autoplay")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Text(player.autoplayFollows.map { "Songs Like \($0)" } ?? "Similar Songs")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(.bottom, 4)
                } else if let context = player.context {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.isStation ? "Playing from Radio" : "Playing From")
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.secondary)
                        Text(player.isRadioDriving ? "\(Image(systemName: "car.fill")) \(context.title) · Driving" : "\(context.title)")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .padding(.bottom, 4)
                }
            }

            Section {
                if player.context?.isStation == true {
                    note("A station picks as it goes, so nothing is queued. Skip to hear the next song.")
                } else if player.upNext.isEmpty {
                    if player.isLive || player.isAutoplaying {
                        note("Picking the next song…")
                    } else if autoplay, player.repeatMode == .off {
                        note("Autoplay will play songs like these once this one ends.")
                    } else {
                        note("Nothing is queued after this song. Choose Play Next on any song to add it here.")
                    }
                } else {
                    ForEach(queued, id: \.track.id) { entry in
                        UpNextRow(track: entry.track, isGettingReady: isGettingReady(entry.track))
                            .tag(entry.track.id)
                            .contextMenu { menu(for: entry.track, at: entry.index) }
                    }
                    .onMove { player.moveUpNext(from: UpNextParts.indices($0, in: queued), to: UpNextParts.index(before: $1, in: queued)) }
                    .onDelete { player.removeUpNext(at: UpNextParts.indices($0, in: queued)) }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Playing Next")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !player.upNext.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    // Tuning opens from the station it changes, presented by the window. In the
                    // header, since the Mac's list leaves a section's footer out.
                    if player.isPlayingTracksRadio, let openRadioTuner {
                        Button("Tune…") { openRadioTuner() }
                            .buttonStyle(.link)
                            .font(.subheadline)
                            .help("How adventurous it is, the genres it leans into, and old favorites")
                    }
                    if !queued.isEmpty, !player.isLive, player.context?.isStation != true {
                        Button("Clear") { player.removeUpNext(at: IndexSet(queued.map(\.index))) }
                            .buttonStyle(.link)
                            .font(.subheadline)
                            .help("Remove every song you queued from Up Next")
                    }
                    if !player.isLive, player.context?.isStation != true {
                        Toggle(isOn: Binding(get: { autoplay }, set: { player.setAutoplay($0) })) {
                            Label("Autoplay", systemImage: "infinity")
                        }
                        .toggleStyle(.button)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(autoplay ? "Autoplay is on: songs like these play once the queue ends" : "Autoplay is off")
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if player.isLive, !player.upNext.isEmpty {
                        if let steering = player.steering {
                            steeringNote(steering)
                        } else {
                            note("\(player.context?.title ?? "") picks each song as the one before starts.")
                        }
                    }
                }
            }

            if !picks.isEmpty {
                Section {
                    ForEach(picks, id: \.track.id) { entry in
                        UpNextRow(track: entry.track, isGettingReady: false)
                            .tag(entry.track.id)
                            .contextMenu { menu(for: entry.track, at: entry.index) }
                    }
                    .onDelete { player.removeUpNext(at: UpNextParts.indices($0, in: picks)) }
                } header: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Autoplay")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(player.autoplayFollows.map { "Songs like \($0), picked as they play" } ?? "Songs like these, picked as they play")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                } footer: {
                    if let steering = player.steering {
                        steeringNote(steering)
                    }
                }
            }

            if player.isLive, !player.playedAndRemoved.isEmpty {
                Section("Played and Removed") {
                    ForEach(player.playedAndRemoved.prefix(4)) { played in
                        HStack(spacing: 10) {
                            CoverImage(cover: played.cover, size: 32)
                            TwoLines(title: played.title, subtitle: played.artistName)
                            Spacer(minLength: 0)
                            Button("Keep", systemImage: "arrow.down.circle") { player.keepPlayed(played) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Download \(played.title) again, to keep it")
                        }
                        .selectionDisabled()
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Clear and the timings stay off the window's edge.
        .contentMargins(.trailing, 8, for: .scrollContent)
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            guard let id = ids.first, let index = player.upNext.firstIndex(where: { $0.id == id }) else { return }
            player.jump(toUpNext: index)
        }
        .onDeleteCommand {
            let offsets = IndexSet(player.upNext.indices.filter { selection.contains(player.upNext[$0].id) })
            guard !offsets.isEmpty else { return }
            player.removeUpNext(at: offsets)
            selection = []
        }
        // Songs dragged here from any list play after everything queued.
        .dropDestination(for: SongDrag.self) { drops, _ in
            playLast(drops)
            return !drops.isEmpty
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.tint, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .animation(PlayMotion.hover, value: isDropTarget)
    }

    private func playLast(_ drops: [SongDrag]) {
        Task {
            for drop in drops {
                guard let request = await drop.request(in: music) else { continue }
                player.enqueue(request, next: false, title: drop.title)
            }
        }
    }

    /// "12 songs, 48 min", while there's a length to add up.
    private var summary: String {
        let count = player.upNext.count
        let seconds = player.upNext.compactMap(\.duration).reduce(0, +)
        let songs = String(AttributedString(localized: "^[\(count) song](inflect: true)").characters)
        guard seconds > 0 else { return songs }
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(songs), \(length)"
    }

    @ViewBuilder
    private func menu(for upcoming: PlayerTrack, at index: Int) -> some View {
        Button("Play Now", systemImage: "play") { player.jump(toUpNext: index) }
        if index > 0 {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.moveUpNext(from: IndexSet(integer: index), to: 0)
            }
        }
        Divider()
        NowPlayingMenuItems(track: upcoming)
        Divider()
        Button("Remove from Up Next", systemImage: "minus.circle", role: .destructive) {
            player.removeUpNext(at: IndexSet(integer: index))
        }
    }

    /// A new find Tracks Radio is getting ready: downloading, or waiting for its server.
    private func isGettingReady(_ track: PlayerTrack) -> Bool {
        guard let local = track.local, local.isFromServer else { return false }
        let copy = music.resolved(local)
        return music.downloads.isDownloading(copy.id) || music.servers.isWaitingToKeep(copy)
    }

    /// What you queued, and after it Autoplay's picks.
    private var queued: [UpNextParts.Entry] { UpNextParts.split(player).queued }
    private var picks: [UpNextParts.Entry] { UpNextParts.split(player).picks }

    private func steeringNote(_ steering: LiveMix.Steering) -> some View {
        Label(steering.line, systemImage: steering.isTurningAway ? "arrow.triangle.turn.up.right.circle.fill" : "scope")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .selectionDisabled()
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .selectionDisabled()
    }
}

/// The song playing, at the top of Up Next, with your count.
private struct NowRow: View {
    let track: PlayerTrack
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(cover: track.cover, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(track.artistName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                PlayCountLine(track: track, showsSince: false)
                    .font(.caption)
                if let reason = player.pickReason(for: track) {
                    PickReasonLabel(reason: reason)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            PanelWaveform()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct UpNextRow: View {
    let track: PlayerTrack
    let isGettingReady: Bool
    @Environment(PlayerModel.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            CoverImage(cover: track.cover, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                TwoLines(
                    title: track.title,
                    subtitle: isGettingReady ? String(localized: "Downloading · \(track.artistName)") : track.artistName
                )
                if let reason = player.pickReason(for: track) {
                    PickReasonLabel(reason: reason)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if let local = track.local {
                DownloadStateIcon(track: local)
            } else if let duration = track.duration {
                Text(Scrubber.format(duration))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-click to play now")
    }
}

/// A title and a line under it, each on one line.
struct TwoLines: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Music's moving bars, in the accent, while the song beside it plays.
private struct PanelWaveform: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        PlayingWaveform(isActive: player.isPlaying)
            .font(.subheadline.weight(.semibold))
            .accessibilityLabel("Now Playing")
    }
}

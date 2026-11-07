import SwiftUI
import TracksCore

/// Up Next, in place of the cover: the song playing, then what's queued, which can be
/// reordered and trimmed. Shuffle and repeat live here, as in Music.
struct QueueView: View {
    let track: PlayerTrack
    /// Shuffle, Repeat and Autoplay, each felt as it's pressed.
    @State private var toggles = 0
    @Environment(PlayerModel.self) private var player
    @Environment(YourMusic.self) private var music
    @AppStorage(PlayPreferences.autoplayKey) private var autoplay = true
    @AppStorage(PlayPreferences.radioTuningKey) private var storedTuning = ""
    @Environment(\.openRadioTuner) private var openRadioTuner
    /// The height of Up Next's rows as drawn, for fitting a live mix's short list to them.
    @State private var listContentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                CoverImage(cover: track.cover, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(1)
                    Text(track.artistName).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    if let reason = player.pickReason(for: track) {
                        PickReasonLabel(reason: reason, lineLimit: 2)
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            #if os(iOS)
            // Beside the song rather than inside it, so it stays a control of its own.
            .safeAreaInset(edge: .trailing, spacing: 12) { SharePlayQueueControl() }
            #endif
            .padding(.top, 20)

            HStack {
                Text("Playing Next")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // A station or a live mix picks as it goes: there's no order to shuffle, end to
                // repeat, or end for Autoplay to follow on from.
                if player.context?.isStation != true, !player.isLive {
                    toggle("Shuffle", "shuffle", isOn: player.isShuffled) { player.toggleShuffle() }
                    toggle(repeatTitle, player.repeatMode == .one ? "repeat.1" : "repeat", isOn: player.repeatMode != .off) {
                        player.cycleRepeat()
                    }
                    toggle("Autoplay", "infinity", isOn: autoplay) { player.setAutoplay(!autoplay) }
                        .accessibilityHint(autoplay ? "Stops playing similar songs when the queue ends" : "Plays similar songs when the queue ends")
                }
            }
            .sensoryFeedback(.selection, trigger: toggles)

            let (queued, picks) = UpNextParts.split(player)
            if player.context?.isStation == true {
                note("A station picks as it goes, so there's nothing queued. Skip to hear the next song.")
            } else if player.upNext.isEmpty {
                if player.isLive || player.isAutoplaying {
                    note("Picking the next song…")
                } else if autoplay, player.repeatMode == .off {
                    note("Autoplay will play songs like these once this one ends.")
                } else if autoplay {
                    note("Autoplay is waiting while Repeat is on.")
                } else {
                    note("Nothing's queued after this song. Use Play Next on any song to add it here, or turn on Autoplay to keep playing songs like these.")
                }
            } else {
                // Long-press to move and swipe to remove, as in Music, rather than edit mode's
                // delete buttons. Autoplay's picks follow what you queued, which can't be moved
                // among them: they're picked one at a time from what plays.
                List {
                    ForEach(queued, id: \.track.id) { entry in
                        row(entry.track, at: entry.index, isLast: entry.track.id == queued.last?.track.id && picks.isEmpty)
                    }
                    .onMove { player.moveUpNext(from: UpNextParts.indices($0, in: queued), to: UpNextParts.index(before: $1, in: queued)) }
                    .onDelete { player.removeUpNext(at: UpNextParts.indices($0, in: queued)) }

                    if !picks.isEmpty {
                        autoplayHeader(isFirst: queued.isEmpty)
                        ForEach(picks, id: \.track.id) { entry in
                            row(entry.track, at: entry.index, isLast: entry.track.id == picks.last?.track.id)
                        }
                        .onDelete { player.removeUpNext(at: UpNextParts.indices($0, in: picks)) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                    listContentHeight = height
                }
                .frame(maxHeight: player.isLive ? liveListHeight : .infinity)

                if player.isLive, !player.playedAndRemoved.isEmpty {
                    playedAndRemoved
                }

                if player.isLive {
                    if let steering = player.steering {
                        steeringNote(steering)
                    } else {
                        note("\(player.context?.title ?? "") picks each song as the one before starts.")
                    }
                } else if !picks.isEmpty, let steering = player.steering {
                    steeringNote(steering)
                }
            }

            if player.isPlayingTracksRadio, let openRadioTuner {
                tuneButton(openRadioTuner)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// What Tracks Radio is tuned to, and the way to change it, under what it's doing: tuning
    /// opens from the station it changes.
    private func tuneButton(_ open: OpenRadioTunerAction) -> some View {
        Button { open() } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tune Tracks Radio")
                        .font(.subheadline.weight(.semibold))
                    Text(RadioTuning(stored: storedTuning).shortSummary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint("How adventurous it is, the genres it leans into, and when it follows the time and the road")
    }

    private func row(_ upcoming: PlayerTrack, at index: Int, isLast: Bool) -> some View {
        Button {
            player.jump(toUpNext: index)
        } label: {
            HStack(spacing: 12) {
                CoverImage(cover: upcoming.cover, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(upcoming.title).lineLimit(1)
                    Text(isGettingReady(upcoming) ? "Downloading · \(upcoming.artistName)" : "\(upcoming.artistName)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    if let reason = player.pickReason(for: upcoming) {
                        PickReasonLabel(reason: reason)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
                if let local = upcoming.local {
                    DownloadStateIcon(track: local)
                        .tint(.white)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .sharePlayMark(upcoming)
        #endif
        .accessibilityHint("Plays this song now")
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(.white.opacity(0.15))
        .listRowSeparator(isLast ? .hidden : .automatic, edges: .bottom)
        .listRowInsets(EdgeInsets(top: Self.rowInsets / 2, leading: 0, bottom: Self.rowInsets / 2, trailing: 0))
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }

    /// Autoplay's heading, as a row of the list so it scrolls with the songs under it.
    private func autoplayHeader(isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Autoplay")
                .font(.headline)
            Text(player.autoplayFollows.map { "Songs like \($0), picked as they play" } ?? "Songs like these, picked as they play")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, isFirst ? 0 : 14)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
    }

    /// What a live mix or Autoplay is doing about what you've skipped and let play.
    private func steeringNote(_ steering: LiveMix.Steering) -> some View {
        Label {
            Text(steering.line)
        } icon: {
            Image(systemName: steering.isTurningAway ? "arrow.triangle.turn.up.right.circle.fill" : "scope")
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.7))
        .fixedSize(horizontal: false, vertical: true)
        .contentTransition(.opacity)
        .animation(.easeOut(duration: 0.2), value: steering)
    }

    /// Finds Tracks Radio played and removed after, to keep one you liked.
    private var playedAndRemoved: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Played and Removed")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ForEach(player.playedAndRemoved.prefix(4)) { played in
                HStack(spacing: 12) {
                    CoverImage(cover: played.cover, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(played.title).lineLimit(1)
                        Text(played.artistName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button("Keep", systemImage: "arrow.down.circle") { player.keepPlayed(played) }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Keep \(played.title)")
                }
                .accessibilityElement(children: .combine)
            }
            note("With Delete After Playing on, new finds leave this iPhone once they've played. Keep one to download it again.")
        }
    }

    /// Room for what's queued on a live mix, usually just the next song, so the note sits
    /// right under it: its rows as drawn, up to four of them, or as they're likely to be until
    /// they're drawn.
    @ScaledMetric(relativeTo: .body) private var liveRowHeight: CGFloat = 57
    private var liveListHeight: CGFloat {
        let most = liveRowHeight * 4
        guard let listContentHeight, listContentHeight > 0 else { return liveRowHeight * CGFloat(min(player.upNext.count, 4)) }
        return min(listContentHeight, most)
    }

    /// The row's insets, top and bottom. See ``row(_:at:isLast:)``.
    private static let rowInsets: CGFloat = 12

    /// A new find Tracks Radio is getting ready: downloading, or waiting for its server.
    private func isGettingReady(_ track: PlayerTrack) -> Bool {
        guard let local = track.local, local.isFromServer else { return false }
        let copy = music.resolved(local)
        return music.downloads.isDownloading(copy.id) || music.servers.isWaitingToKeep(copy)
    }

    private var repeatTitle: LocalizedStringKey {
        switch player.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            toggles += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.black : .white.opacity(0.8))
                .frame(width: 40, height: 30)
                .background(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.15)), in: .capsule)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Up Next split in two, as Music shows it: what you queued, then Autoplay's picks, each with
/// its place in the queue, which is what the player's moves and removals go by. They're
/// usually one run then the other, but shuffling can mix them.
enum UpNextParts {
    typealias Entry = (index: Int, track: PlayerTrack)

    @MainActor
    static func split(_ player: PlayerModel) -> (queued: [Entry], picks: [Entry]) {
        let entries = player.upNext.enumerated().map { Entry(index: $0.offset, track: $0.element) }
        return (entries.filter { !player.isAutoplayPick($0.track) }, entries.filter { player.isAutoplayPick($0.track) })
    }

    /// Offsets into one part, as places in the queue.
    static func indices(_ offsets: IndexSet, in part: [Entry]) -> IndexSet {
        IndexSet(offsets.compactMap { part.indices.contains($0) ? part[$0].index : nil })
    }

    /// A move's destination in one part, as a place in the queue: before the entry now there,
    /// or just after the part's last.
    static func index(before offset: Int, in part: [Entry]) -> Int {
        if part.indices.contains(offset) { return part[offset].index }
        return (part.last?.index).map { $0 + 1 } ?? 0
    }
}

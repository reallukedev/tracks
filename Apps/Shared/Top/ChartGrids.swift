import SwiftUI
import TracksCore

/// Top Artists as a wall of portraits: who they are first, then where they stand, how much
/// of them you played, and the song of theirs that did it. An artist heard for the first
/// time says so.
struct ArtistChartGrid: View {
    let entries: [ChartEntry]
    let open: (ChartEntry) -> Void
    /// Whether any of an entry's songs can play here, so a tile with none offers no Play.
    let canPlay: (ChartEntry) -> Bool
    let play: (ChartEntry) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimum), spacing: 20, alignment: .top)], spacing: 28) {
            ForEach(entries.enumerated(), id: \.element.id) { index, entry in
                ArtistChartTile(position: index + 1, entry: entry, open: { open(entry) }, play: canPlay(entry) ? { play(entry) } : nil)
            }
        }
    }

    #if os(macOS)
    private static let minimum: CGFloat = 150
    #else
    private static let minimum: CGFloat = 104
    #endif
}

private struct ArtistChartTile: View {
    let position: Int
    let entry: ChartEntry
    let open: () -> Void
    let play: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 10) {
                ArtworkView(url: entry.artworkURL, seed: entry.artworkSeed, isCircle: true)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(isHovered ? 0.28 : 0.16), radius: isHovered ? 14 : 8, y: isHovered ? 8 : 4)
                    .scaleEffect(isHovered ? 1.03 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if isHovered, let play {
                            ChartTilePlayButton(title: entry.title, play: play)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                VStack(spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(position.formatted())
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(entry.title)
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Text(amounts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    if entry.isNew {
                        Text("New to You")
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .foregroundStyle(.tint)
                            .padding(.top, 1)
                    } else if let detail = entry.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PlayMotion.hover) { isHovered = hovering }
        }
        .contextMenu {
            if let play {
                Button("Play Their Songs", systemImage: "play", action: play)
            }
            Button("Your Stats", systemImage: "chart.bar.xaxis", action: open)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Number \(position), \(entry.title), \(amounts)"))
        .accessibilityHint("Opens your stats")
        .accessibilityActions {
            if let play {
                Button("Play Their Songs", action: play)
            }
        }
    }

    /// "134 plays · 12 songs".
    private var amounts: String {
        let plays = PlayCountText.short(entry.count)
        guard let songs = entry.songCount else { return plays }
        let heard = String(AttributedString(localized: "^[\(songs) song](inflect: true)").characters)
        return "\(plays) · \(heard)"
    }
}

/// Top Albums as the records on the shelf: each cover, where it stands, and how deep you
/// went into it.
struct AlbumChartGrid: View {
    let entries: [ChartEntry]
    let open: (ChartEntry) -> Void
    /// Whether any of an entry's songs can play here, so a tile with none offers no Play.
    let canPlay: (ChartEntry) -> Bool
    let play: (ChartEntry) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimum), spacing: 20, alignment: .top)], spacing: 26) {
            ForEach(entries.enumerated(), id: \.element.id) { index, entry in
                AlbumChartTile(position: index + 1, entry: entry, open: { open(entry) }, play: canPlay(entry) ? { play(entry) } : nil)
            }
        }
    }

    #if os(macOS)
    private static let minimum: CGFloat = 168
    #else
    private static let minimum: CGFloat = 150
    #endif
}

private struct AlbumChartTile: View {
    let position: Int
    let entry: ChartEntry
    let open: () -> Void
    let play: (() -> Void)?
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 9) {
                ArtworkView(url: entry.artworkURL, seed: entry.artworkSeed, maximumCornerRadius: 8)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(isHovered ? 0.28 : 0.16), radius: isHovered ? 14 : 8, y: isHovered ? 8 : 4)
                    .overlay(alignment: .bottomTrailing) {
                        if isHovered, let play {
                            ChartTilePlayButton(title: entry.title, play: play)
                                .padding(8)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(position.formatted())
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let artist = entry.subtitle {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(amounts)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(PlayMotion.hover) { isHovered = hovering }
        }
        .contextMenu {
            if let play {
                Button("Play What You Played", systemImage: "play", action: play)
            }
            Button("Your Stats", systemImage: "chart.bar.xaxis", action: open)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Number \(position), \(entry.title), \(entry.subtitle ?? ""), \(amounts)"))
        .accessibilityHint("Opens your stats")
        .accessibilityActions {
            if let play {
                Button("Play", action: play)
            }
        }
    }

    /// "34 plays · 9 songs".
    private var amounts: String {
        let plays = PlayCountText.short(entry.count)
        guard let songs = entry.songCount else { return plays }
        let heard = String(AttributedString(localized: "^[\(songs) song](inflect: true)").characters)
        return "\(plays) · \(heard)"
    }
}

/// The play button a tile shows under the pointer, as Music's covers do.
private struct ChartTilePlayButton: View {
    let title: String
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Label("Play \(title)", systemImage: "play.fill")
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.55), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help("Play \(title)")
    }
}

/// Who a period's listening went to: the top artists' shares of it, side by side in one bar,
/// as Storage shows what fills a disk.
struct ArtistShareBar: View {
    let entries: [ChartEntry]
    let plays: Int

    private static let palette: [Color] = [.accentColor, .blue, .teal, .orange, .pink]

    /// What the shares are of. A collaboration counts for each artist on it, so the artists'
    /// plays can add up to more than the period's, and the bar is cut from their sum then.
    private var whole: Int {
        max(plays, entries.reduce(0) { $0 + $1.count })
    }

    private var shares: [(name: String, plays: Int, color: Color)] {
        let top = entries.prefix(Self.palette.count)
        var shares = zip(top, Self.palette).map { ($0.title, $0.count, $1) }
        let rest = whole - top.map(\.count).reduce(0, +)
        if rest > 0 { shares.append((String(localized: "Everyone Else"), rest, Color.secondary.opacity(0.35))) }
        return shares
    }

    var body: some View {
        let shares = shares
        let whole = whole
        VStack(alignment: .leading, spacing: 12) {
            Text("Who You Listened To")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(shares.enumerated(), id: \.offset) { _, share in
                        Rectangle()
                            .fill(share.color)
                            .frame(width: max(2, (proxy.size.width - CGFloat(shares.count - 1) * 2) * CGFloat(share.plays) / CGFloat(max(whole, 1))))
                    }
                }
                .clipShape(.capsule)
            }
            .frame(height: 14)
            .accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(shares.enumerated(), id: \.offset) { _, share in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(share.color)
                            .frame(width: 8, height: 8)
                        Text(share.name)
                            .lineLimit(1)
                        Text((Double(share.plays) / Double(max(whole, 1))).formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// The album gone deepest into in a period: the one with the most of its songs played.
struct DeepestListen: View {
    let entry: ChartEntry

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(url: entry.artworkURL, seed: entry.artworkSeed, size: 64)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Deepest Listen")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(entry.songCount ?? 0) songs from \(Text(entry.title).fontWeight(.semibold))")
                    .font(.body)
                    .lineLimit(2)
                if let artist = entry.subtitle {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import TracksCore

/// One play in the history. Shared by the iPhone History list and the Mac menu bar.
struct CaptureRow: View {
    let capture: Capture
    /// Whether to show the time and status glyphs on the right. Off in the menu bar's
    /// "now playing" slot, which is a glance rather than a record.
    var showsStatus = true
    /// Pass true when a Last.fm account is connected, so unsent scrobbles get a clock.
    var showsScrobbleState = false
    var artworkSize: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                row
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    /// At accessibility sizes: cover on top, then each line full width.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkView(url: capture.artworkURL, seed: capture.albumTitle ?? capture.title, size: artworkSize)
            Text(capture.title)
            artist
                .foregroundStyle(.secondary)
            if showsStatus {
                Text(capture.capturedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            ArtworkView(
                url: capture.artworkURL,
                seed: capture.albumTitle ?? capture.title,
                size: artworkSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if capture.kind == .radio {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.pink)
                            .accessibilityHidden(true)
                    }
                    artist
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showsStatus {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(capture.capturedAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    HStack(spacing: 4) {
                        if showsScrobbleState, capture.scrobbledAt == nil {
                            if capture.isHeldFromScrobbling {
                                // Not a failure: too short for Last.fm to count, so quiet.
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.tertiary)
                            } else {
                                let gaveUp = capture.scrobbleAttempts >= TracksStore.maxScrobbleAttempts
                                Image(systemName: gaveUp ? "exclamationmark.circle" : "clock")
                                    .foregroundStyle(gaveUp ? .orange : .secondary)
                            }
                        }
                        if !capture.kind.sourceIsKnown {
                            Image(systemName: capture.kind.symbol)
                                .foregroundStyle(capture.kind.tint)
                        }
                        playlistState
                    }
                    .font(.caption2)
                }
            }
        }
    }

    /// Each name opens your history's page for them.
    private var artist: some View {
        CreditedText(
            text: capture.artistName,
            credits: ArtistCredits.song(artist: capture.artistName, title: capture.title),
            linkStyle: .row
        )
    }

    /// Radio only, since nothing else goes into the playlist.
    @ViewBuilder
    private var playlistState: some View {
        if capture.kind == .radio {
            if capture.addedToPlaylistAt != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if capture.needsPlaylistWrite {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var accessibilityLabel: String {
        let time = capture.capturedAt.formatted(date: .omitted, time: .shortened)
        switch capture.kind {
        case .radio: return String(localized: "\(capture.title) by \(capture.artistName), heard on the radio at \(time)")
        case .imported: return String(localized: "\(capture.title) by \(capture.artistName), recovered from Recently Played")
        case .onDemand: return String(localized: "\(capture.title) by \(capture.artistName), at \(time)")
        case .lastFM: return String(localized: "\(capture.title) by \(capture.artistName), from Last.fm at \(time)")
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if showsScrobbleState {
            if capture.scrobbledAt != nil {
                parts.append(String(localized: "Scrobbled"))
            } else if capture.isHeldFromScrobbling {
                parts.append(String(localized: "Not long enough for Last.fm to count"))
            } else {
                parts.append(String(localized: "Not scrobbled yet"))
            }
        }
        if capture.kind == .radio {
            if capture.addedToPlaylistAt != nil {
                parts.append(String(localized: "In your radio playlist"))
            } else if capture.needsPlaylistWrite {
                parts.append(String(localized: "Waiting to be added to the playlist"))
            } else {
                parts.append(String(localized: "Couldn't be added to the playlist"))
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// A song that's playing but hasn't been kept yet. Same shape as `CaptureRow` so the menu
/// bar doesn't jump when it becomes one.
struct NowPlayingRow: View {
    let song: NowPlaying

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: song.artworkURL, seed: song.albumTitle ?? song.title, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playing: \(song.title) by \(song.artistName)")
    }
}

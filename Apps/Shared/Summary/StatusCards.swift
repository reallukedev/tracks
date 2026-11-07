import SwiftUI
import MusicKit
import TracksCore

/// What's playing right now, shown at the top of Summary while there's music.
struct NowPlayingCard: View {
    @Environment(CaptureService.self) private var capture
    @AppStorage(CaptureSettings.scrobblesToLastFMKey, store: CaptureSettings.sharedDefaults)
    private var scrobbles = true
    /// Follows connecting and disconnecting in Settings, without a Keychain read per render.
    @AppStorage(LastFMSessionStore.usernameDefaultsKey, store: CaptureSettings.sharedDefaults)
    private var lastFMUsername: String?
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let song = capture.nowPlaying {
            Card(padding: 12) {
                HStack(spacing: 12) {
                    cover(of: song)
                    VStack(alignment: .leading, spacing: 2) {
                        Label {
                            Text(caption)
                        } icon: {
                            PlayingWaveform(isActive: true)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                        Text(song.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(song.artistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityElement(children: .combine)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }

    /// Tracks’ own player has the song's cover to hand, even one only MusicKit can draw, and
    /// before any lookup: used when it's the one playing. Otherwise the cover capture found.
    @ViewBuilder
    private func cover(of song: NowPlaying) -> some View {
        if let track = player.current, player.isPlaying,
           track.title == song.title, track.artistName == song.artistName {
            CoverImage(cover: track.cover, size: 52)
        } else {
            ArtworkView(url: song.artworkURL, seed: song.albumTitle ?? song.title, size: 52)
        }
    }

    private var caption: LocalizedStringKey {
        if let station = capture.currentStation, capture.lastCapture?.kind == .radio {
            return "Playing on \(station)"
        }
        return lastFMUsername != nil && scrobbles ? "Now Playing · Scrobbling" : "Now Playing"
    }
}

/// When the real store couldn't be opened and we fell back to memory, nothing will be kept.
struct StoreWarningBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The reason is for diagnostics, in the backing's description, not for the banner.
        if !model.isShowingSampleData, case .inMemory = model.store?.backing {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your listening isn't being saved")
                        .font(.subheadline.weight(.semibold))
                    Text("Tracks couldn't open its library, so what you play now will be lost when it quits. Quit and reopen Tracks to try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: Metrics.cardRadius, style: .continuous))
        }
    }
}

/// The first-run screen: what Tracks does, before there's any history.
struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView {
                Label("No Listening Yet", systemImage: "waveform")
            } description: {
                Text("Play something in Tracks or Apple Music. Tracks keeps every song you hear, radio included, and turns them into charts and highlights.")
            }
            // First run is when the reason for Apple Music access is easiest to see.
            MusicAccessCard()
                .frame(maxWidth: 520)
        }
    }
}

/// Explains Apple Music access and asks for it, or says how to turn it back on.
///
/// Tracks doesn't ask at launch: a prompt with no context is easy to refuse, and capture
/// works without access. Shows nothing once access is granted, or with sample data.
struct MusicAccessCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false

    var body: some View {
        if !model.isShowingSampleData, model.musicAuthorization != .authorized {
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                    } icon: {
                        Image(systemName: model.musicAuthorization == .notDetermined ? "music.note" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.musicAuthorization == .notDetermined ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                    }
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    action
                }
            }
            .onAppear(perform: model.refreshMusicAuthorization)
        }
    }

    private var title: LocalizedStringKey {
        switch model.musicAuthorization {
        case .denied: "Apple Music Access Is Off"
        case .restricted: "Apple Music Access Is Restricted"
        default: "Let Tracks Use Apple Music"
        }
    }

    private var message: LocalizedStringKey {
        switch model.musicAuthorization {
        case .denied:
            "Tracks still keeps what you play here, but it can't fill in songs from Recently Played, find artwork, or add radio songs to your playlist. Turn on access for Tracks in \(Self.settingsName)."
        case .restricted:
            "This device limits access to Apple Music, for example with Screen Time. Tracks still keeps what you play, but can't fill in songs from Recently Played, find artwork, or add radio songs to your playlist."
        default:
            "Tracks already keeps what you play. With access it can also fill in songs you played while it was closed, find artwork, and add radio songs to your playlist."
        }
    }

    @ViewBuilder
    private var action: some View {
        switch model.musicAuthorization {
        case .notDetermined:
            Button("Allow Apple Music Access") {
                isRequesting = true
                Task {
                    await model.requestMusicAccess()
                    isRequesting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)
        default:
            Button(Self.openSettingsTitle) {
                if let url = Self.settingsURL { openURL(url) }
            }
            .buttonStyle(.bordered)
        }
    }

    #if os(iOS)
    private static var settingsName: String { String(localized: "Settings") }
    private static let openSettingsTitle: LocalizedStringKey = "Open Settings"
    private static let settingsURL = URL(string: UIApplication.openSettingsURLString)
    #else
    private static var settingsName: String {
        String(localized: "System Settings › Privacy & Security › Media & Apple Music")
    }
    private static let openSettingsTitle: LocalizedStringKey = "Open System Settings"
    /// Privacy & Security › Media & Apple Music.
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")
    #endif
}

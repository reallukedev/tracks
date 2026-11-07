import SwiftUI
import MusicKit
import TracksCore

/// Apple Music access: what it's for, and asking for it or turning it back on; and the audio
/// quality it's playing at, with where that's chosen. An iPhone page; on the Mac, the same
/// section sits in the General pane.
struct AppleMusicSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = MusicAccessStatus(model.musicAuthorization)
        Form {
            SettingsHero(
                "Apple Music",
                subtitle: status.tone.apply(to: Text(status.line)),
                systemImage: "music.note",
                tint: .pink
            )
            AppleMusicAccessSection()
            #if os(iOS)
            AppleMusicQualitySection()
            #endif
        }
        #if os(iOS)
        .settingsPage("Apple Music")
        #endif
    }
}

/// Asking for access, or the way to turn it back on in Settings.
struct AppleMusicAccessSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var isRequesting = false

    private var status: MusicAccessStatus { MusicAccessStatus(model.musicAuthorization) }

    var body: some View {
        Section {
            #if os(macOS)
            SettingsDetailRow(
                title: Text("Access"),
                detail: status.tone.apply(to: Text(status.line))
            ) {
                control
            }
            // The Mac's General pane holds this one section, so the quality row joins it.
            AppleMusicQualityRow()
            #else
            // Allowed needs no row: the status line above already says so.
            control
            #endif
        } header: {
            #if os(macOS)
            Text("Apple Music")
            #endif
        } footer: {
            footer
        }
        .onAppear(perform: model.refreshMusicAuthorization)
    }

    @ViewBuilder
    private var control: some View {
        switch status {
        case .allowed, .restricted:
            // Restricted has nothing to press: the device's owner decides.
            EmptyView()
        case .notAsked:
            // Asked only from a button someone pressed, never as the page opens.
            Button("Allow Access…") {
                isRequesting = true
                Task {
                    await model.requestMusicAccess()
                    isRequesting = false
                }
            }
            .disabled(isRequesting || model.isShowingSampleData)
        case .denied:
            Button(openSettingsTitle) {
                if let settingsURL { openURL(settingsURL) }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch status {
        case .denied:
            Text(turnOnPath)
        case .restricted:
            Text("Screen Time or a device profile doesn’t allow Apple Music access.")
        case .notAsked where model.isShowingSampleData:
            Text("Not available while Tracks shows sample data.")
        case .notAsked:
            Text("Tracks keeps what you play either way. Apple Music asks before anything is shared.")
        case .allowed:
            Text(turnOffPath)
        }
    }

    #if os(iOS)
    private var openSettingsTitle: LocalizedStringKey { "Open Settings…" }
    private var settingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }
    private var turnOnPath: LocalizedStringKey { "To turn it on, go to Settings ▸ Apps ▸ Tracks and turn on Media & Apple Music." }
    private var turnOffPath: LocalizedStringKey { "You can turn access off in Settings ▸ Apps ▸ Tracks." }
    #else
    private var openSettingsTitle: LocalizedStringKey { "Open System Settings…" }
    /// Privacy & Security ▸ Media & Apple Music.
    private var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")
    }
    private var turnOnPath: LocalizedStringKey { "To turn it on, go to System Settings ▸ Privacy & Security ▸ Media & Apple Music." }
    private var turnOffPath: LocalizedStringKey { "You can turn access off in System Settings ▸ Privacy & Security ▸ Media & Apple Music." }
    #endif
}

/// What Apple Music is playing at right now, from its player, or that it isn't playing.
private struct AppleMusicNowPlayingQuality: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let quality = player.current.flatMap { AudioQualityBadge.appleMusicQuality(of: $0, in: player) }
        HStack(spacing: 4) {
            if quality?.showsWaveform == true {
                Image(systemName: "waveform")
                    .accessibilityHidden(true)
            }
            Text(AudioQualityWords.appleMusicNowPlaying(quality))
        }
        .foregroundStyle(.secondary)
    }
}

#if os(iOS)
/// Apple Music's audio quality on iPhone: what's playing now, and where Lossless and the
/// Wi-Fi, cellular and download choices live. MusicKit has no way to change them, so there
/// are no controls here that couldn't work.
struct AppleMusicQualitySection: View {
    var body: some View {
        Section {
            LabeledContent("Now Playing") {
                AppleMusicNowPlayingQuality()
            }
        } header: {
            Text("Audio Quality")
        } footer: {
            Text(AudioQualityWords.appleMusicWhere)
        }
    }
}
#else
/// Apple Music's audio quality on the Mac, a row of the Apple Music section in General:
/// what's playing now, and where Music chooses it.
struct AppleMusicQualityRow: View {
    var body: some View {
        SettingsDetailRow(title: Text("Audio Quality"), detail: Text(AudioQualityWords.appleMusicWhere)) {
            AppleMusicNowPlayingQuality()
        }
    }
}
#endif

extension MusicAccessStatus {
    init(_ authorization: MusicAuthorization.Status) {
        switch authorization {
        case .authorized: self = .allowed
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notAsked
        @unknown default: self = .notAsked
        }
    }
}

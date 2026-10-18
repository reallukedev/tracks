#if os(iOS)
import SwiftUI
import TracksCore

/// Settings ▸ Play on iPhone: where Play's music comes from, Tracks Radio, where Tracks opens,
/// explicit songs, how one song leads into the next, the Play tab's layout, and the memory
/// behind its mixes. The Mac has its own pane, `PlaySettingsPane`.
struct PlaySettingsPage: View {
    @AppStorage(OpeningTab.storageKey) private var openingTab: OpeningTab = .standard
    @AppStorage(PlayPreferences.allowsExplicitKey) private var allowsExplicit = true
    @AppStorage(PlayPreferences.transitionKey) private var transition: SongTransition = .off
    @AppStorage(PlayPreferences.crossfadeSecondsKey) private var crossfadeSeconds = PlayPreferences.defaultCrossfadeSeconds
    @AppStorage(PlayPreferences.tracksRadioKey) private var isRadioOn = true
    @AppStorage(PlayPreferences.radioTuningKey) private var storedTuning = ""
    @AppStorage(PlayPreferences.layoutKey) private var storedLayout = ""
    @AppStorage(PlayPreferences.songDestinationKey) private var songDestination = SongDestination.tracks
    @AppStorage(StreamQuality.wiFiKey) private var wiFiQuality = StreamQuality.original
    @AppStorage(StreamQuality.cellularKey) private var cellularQuality = StreamQuality.original
    @AppStorage(StreamQuality.downloadKey) private var downloadQuality = StreamQuality.original
    @AppStorage(AutomaticDownloads.storageKey) private var automaticDownloads = true
    @AppStorage(PlayPreferences.radioDownloadsFirstKey) private var radioDownloadsFirst = true
    @AppStorage(PlayPreferences.radioDeletesAfterPlayingKey) private var radioDeletesAfterPlaying = false
    @AppStorage(PlayPreferences.shakeToPlayKey) private var shakeToPlay = true
    @AppStorage(QuickSwitch.storageKey) private var quickSwitch = false
    @AppStorage(SuggestionMode.storageKey) private var suggestionMode = SuggestionMode.everything
    @AppStorage(OfflineMode.storageKey) private var isOfflineModeOn = false
    @Environment(DownloadedSongs.self) private var downloads
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var layout: PlayLayout { PlayLayout(stored: storedLayout) }
    private var isYourMusic: Bool { model.musicSource == .yourMusic }

    var body: some View {
        let status = PlaySettingsWords.status(standing)
        ScrollViewReader { proxy in
            Form {
                SettingsHero("Play", subtitle: status.tone.apply(to: Text(status.line)), systemImage: "play.fill", tint: .indigo)

                sourceSection
                if isYourMusic {
                    yourMusicSections
                } else {
                    offlineSection
                }
                radioSection
                    .id(DebugScroll.radio)
                drivingSection
                    .id(DebugScroll.driving)
                aroundSection
                ResumeSettingsSection()
                NowPlayingBackdropSection()
                devicesSection
                contentSection
                BlockedArtistsSection()
                if !isYourMusic {
                    // Your Music plays gaplessly, with no crossfade, and has its own Play page.
                    transitionSection
                    layoutSection
                }
                PlaySettingsMixes()
                    .id(DebugScroll.mixes)
            }
            #if DEBUG
            // -TracksSettingsScroll radio (or mixes) opens the page scrolled there, for screenshots.
            .task {
                guard let target = UserDefaults.standard.string(forKey: "TracksSettingsScroll").flatMap(DebugScroll.init) else { return }
                try? await Task.sleep(for: .seconds(1))
                proxy.scrollTo(target, anchor: .top)
            }
            #endif
        }
        // Menus truncate their value beside a long label at the largest sizes; a pushed list
        // shows every option in full.
        .modifier(AccessiblePickers())
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: model.musicSource)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: transition)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: isRadioOn)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: radioDownloadsFirst)
        .settingsPage("Play")
    }

    /// Places `-TracksSettingsScroll` can open the page at.
    private enum DebugScroll: String {
        case radio, mixes, driving
    }

    private var standing: PlaySettingsWords.Standing {
        PlaySettingsWords.Standing(
            model: model,
            music: music,
            offlineSongs: isOfflineModeOn && downloads.hasLoaded ? downloads.songs.count : nil
        )
    }

    // MARK: - Source

    private var sourceSection: some View {
        @Bindable var model = model
        return Section {
            Picker("Music Source", selection: $model.musicSource) {
                ForEach(MusicSource.allCases) { source in
                    Label(source.title, systemImage: source.symbol).tag(source)
                }
            }
            if QuickSwitch.isAvailable(music) {
                Toggle("Quick Switch", isOn: $quickSwitch)
            }
        } header: {
            Text("Source")
        } footer: {
            Text(PlaySettingsWords.sourceFooter(model.musicSource, quickSwitch: .init(music: music, isOn: quickSwitch)))
                .contentTransition(.opacity)
        }
    }

    private var offlineSection: some View {
        Section {
            Toggle("Offline Mode", isOn: $isOfflineModeOn)
            if downloads.hasLoaded {
                LabeledContent("Downloaded Songs") {
                    Text(downloads.songs.count, format: .number)
                        .monospacedDigit()
                }
            }
        } header: {
            Text("Offline")
        } footer: {
            Text("Play shows only songs downloaded to this iPhone, which play without a connection. It switches to them by itself when you’re offline. To download songs you add to your library from Tracks, turn on Automatic Downloads in Settings ▸ Apps ▸ Music.")
        }
        .task { await downloads.loadIfNeeded() }
    }

    // MARK: - Your Music

    @ViewBuilder
    private var yourMusicSections: some View {
        Section {
            LabeledContent("Songs on iPhone") {
                Text(music.fileTracks.count, format: .number)
                    .monospacedDigit()
            }
            // A size of nothing reads as a fault, not a fact.
            if music.fileBytes > 0 {
                LabeledContent("Space Used", value: LocalFormat.bytes(music.fileBytes))
            }
            Button {
                Task { await music.scan() }
            } label: {
                HStack {
                    Label(music.isScanning ? "Looking for Songs…" : "Look for New Songs", systemImage: "arrow.clockwise")
                    Spacer()
                    if music.isScanning { ProgressView() }
                }
            }
            .disabled(music.isScanning)
        } header: {
            Text("On This iPhone")
        } footer: {
            Text("Add songs from Play, or put them in On My iPhone ▸ Tracks ▸ Music in the Files app. FLAC, ALAC, MP3, AAC, WAV and AIFF all play, with their tags and covers.")
        }

        ServersSection()

        Section {
            Picker("Suggest", selection: $suggestionMode) {
                ForEach(SuggestionMode.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Suggestions")
        } footer: {
            Text(PlaySettingsWords.suggestionFooter(suggestionMode))
                .contentTransition(.opacity)
        }

        PlaySettingsPlaylistMerge()

        LidarrSettingsLink()

        Section {
            NavigationLink {
                DownloadsPage()
            } label: {
                LabeledContent("Downloaded", value: LocalFormat.bytes(music.downloads.totalBytes))
            }
            Toggle("Automatic Downloads", isOn: $automaticDownloads)
            StreamQualityPicker(title: "Streaming on Wi-Fi", selection: $wiFiQuality)
            StreamQualityPicker(title: "Streaming on Cellular", selection: $cellularQuality)
            StreamQualityPicker(title: "Download Quality", selection: $downloadQuality)
        } header: {
            Text("Downloads and Streaming")
        } footer: {
            Text(PlaySettingsWords.downloadsFooter(automatic: automaticDownloads, wiFi: wiFiQuality, cellular: cellularQuality, download: downloadQuality))
                .contentTransition(.opacity)
        }
    }

    // MARK: - Tracks Radio

    private var radioSection: some View {
        Section {
            Toggle("Show Tracks Radio", isOn: $isRadioOn)
            if isRadioOn {
                // Pushed, as Settings rows are: the same tuner its artwork opens as a sheet.
                NavigationLink {
                    RadioTuner()
                } label: {
                    LabeledContent("Tune Tracks Radio", value: RadioTuning(stored: storedTuning).shortSummary)
                }
                if isYourMusic {
                    Toggle("Downloaded Songs First", isOn: $radioDownloadsFirst)
                    if radioDownloadsFirst {
                        Toggle("Delete After Playing", isOn: $radioDeletesAfterPlaying)
                    }
                }
            }
        } header: {
            Text("Tracks Radio")
        } footer: {
            Text(radioFooter)
                .contentTransition(.opacity)
        }
    }

    private var radioFooter: String {
        PlaySettingsWords.radioFooter(
            isOn: isRadioOn,
            place: PlaySettingsWords.RadioPlace(
                source: model.musicSource,
                showsForYou: layout.isVisible(.forYou),
                showsSuggestedSongs: layout.isVisible(.suggestedSongs),
                suggests: suggestionMode != .off
            ),
            downloadsFirst: radioDownloadsFirst,
            deletesAfterPlaying: radioDeletesAfterPlaying
        )
    }

    // MARK: - Driving

    /// Louder at Speed's row, saying where it stands, pushing its own page.
    private var drivingSection: some View {
        let standing = SpeedVolume.shared.standing(motion: model.player.drive.access, isAppleMusic: !model.player.setsOwnLevel)
        return Section {
            NavigationLink {
                SpeedVolumePage()
            } label: {
                LabeledContent("Louder at Speed", value: SpeedVolumeWords.rowValue(standing))
            }
        } header: {
            Text("Driving")
        } footer: {
            Text("Your music comes up on the highway and down at the lights, following the car.")
        }
    }

    // MARK: - Around Tracks

    private var aroundSection: some View {
        Section {
            Picker("Open To", selection: $openingTab) {
                ForEach(OpeningTab.allCases) { tab in
                    Text(PlaySettingsWords.openingName(tab)).tag(tab)
                }
            }
            Picker("Play Songs In", selection: $songDestination) {
                ForEach(SongDestination.allCases) { destination in
                    Text(PlaySettingsWords.destinationName(destination)).tag(destination)
                }
            }
        } header: {
            Text("Around Tracks")
        } footer: {
            Text("\(PlaySettingsWords.openingFooter(openingTab)) \(PlaySettingsWords.destinationFooter(songDestination))")
                .contentTransition(.opacity)
        }
    }

    private var devicesSection: some View {
        Section {
            Toggle("Shake to Play", isOn: $shakeToPlay)
        } footer: {
            Text(PlaySettingsWords.shakeFooter(shakeToPlay))
                .contentTransition(.opacity)
        }
    }

    // MARK: - Playback

    private var contentSection: some View {
        Section {
            Toggle("Explicit Songs", isOn: $allowsExplicit)
        } header: {
            Text("Content")
        } footer: {
            Text(PlaySettingsWords.explicitFooter(allowsExplicit))
                .contentTransition(.opacity)
        }
    }

    private var transitionSection: some View {
        Section {
            Picker("Song Transitions", selection: $transition) {
                ForEach(SongTransition.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            if transition == .crossfade {
                SettingsSliderRow(
                    title: "Crossfade Length",
                    value: $crossfadeSeconds,
                    range: PlayPreferences.crossfadeRange,
                    step: 1,
                    minimumLabel: Text(Self.seconds(PlayPreferences.crossfadeRange.lowerBound)),
                    maximumLabel: Text(Self.seconds(PlayPreferences.crossfadeRange.upperBound)),
                    describe: Self.seconds
                )
            }
        } header: {
            Text("Transitions")
        } footer: {
            Text(PlaySettingsWords.transitionFooter(transition))
                .contentTransition(.opacity)
        }
    }

    private var layoutSection: some View {
        Section {
            NavigationLink {
                PlayLayoutList()
                    .navigationTitle("Edit Play Tab")
                    .toolbarTitleDisplayMode(.inline)
            } label: {
                LabeledContent("Edit Play Tab", value: PlaySettingsWords.layoutValue(layout))
            }
        } header: {
            Text("Layout")
        } footer: {
            Text("Choose which sections Play shows, and their order.")
        }
    }

    /// "6 sec": short enough for the ends of the slider and its value.
    static func seconds(_ value: Double) -> String {
        Duration.seconds(value).formatted(.units(allowed: [.seconds], width: .abbreviated))
    }
}
/// Menu pickers at most sizes; at the accessibility sizes, pickers that push a list, since a
/// menu's value truncates beside a label that already fills the row.
private struct AccessiblePickers: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.navigationLink)
        } else {
            content
        }
    }
}
#endif

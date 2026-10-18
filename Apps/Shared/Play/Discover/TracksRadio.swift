import SwiftUI
import TracksCore

extension RadioTuning {
    /// "Songs you love and new finds, leaning into Hip-Hop and R&B", for the tuner's header.
    var summary: String {
        var line = discovery.summary
        let genres = genres.sorted()
        if !genres.isEmpty {
            line += String(localized: ", leaning into \(genreList)")
        }
        return line
    }

    /// "Balanced · Hip-Hop", short enough for one line on the station's artwork.
    var shortSummary: String {
        genres.isEmpty ? discovery.title : "\(discovery.title) · \(genreList)"
    }

    /// "Hip-Hop and R&B", or "Hip-Hop, R&B and more".
    var genreList: String {
        let genres = genres.sorted()
        return genres.count > 2
            ? String(localized: "\(genres[0]), \(genres[1]) and more")
            : genres.formatted(.list(type: .and))
    }
}

extension RadioTuning.Discovery {
    var title: String {
        switch self {
        case .familiar: String(localized: "Familiar")
        case .balanced: String(localized: "Balanced")
        case .adventurous: String(localized: "Adventurous")
        }
    }

    var summary: String {
        switch self {
        case .familiar: String(localized: "Mostly songs you love")
        case .balanced: String(localized: "Songs you love and new finds")
        case .adventurous: String(localized: "Lots of new finds")
        }
    }

    var detail: String {
        switch self {
        case .familiar: String(localized: "Mostly songs you love, with a new find now and then.")
        case .balanced: String(localized: "Songs you love, and about one new find in four.")
        case .adventurous: String(localized: "Half new finds, from artists like yours.")
        }
    }
}

/// What Tracks Radio's Time and Driving settings say, for the tuner and the Mac's Play pane.
enum RadioMomentWords {
    static func timeDetail(_ followsTime: Bool) -> String {
        followsTime
            ? String(localized: "Plays what you usually play at this hour, with a feel for each part of the day.")
            : String(localized: "Plays the same at any hour.")
    }

    static func driveDetail(_ access: DriveDetector.Access) -> String {
        access == .denied
            ? String(localized: "Motion & Fitness is off for Tracks, so only CarPlay counts as driving.")
            : String(localized: "While you’re driving or on CarPlay, it plays the songs you play on the road, with steady energy and fewer new finds. Your drives stay on this iPhone.")
    }

    /// The footer under both settings, saying what each does as it's set.
    static func footer(followsTime: Bool, day: RadioDay, noticesDriving: Bool, access: DriveDetector.Access) -> String {
        var lines = [followsTime
            ? String(localized: "Tracks Radio plays what you usually play at this hour, \(RadioDayWords.clause(day)).")
            : String(localized: "Tracks Radio plays the same at any hour.")]
        if noticesDriving { lines.append(driveDetail(access)) }
        return lines.joined(separator: " ")
    }
}

// MARK: - The station's artwork

/// Tracks Radio's artwork, as Apple Music draws a personal station's: one rich field of
/// Tracks’ colour with the station's name set in it. While it plays, a waveform in the corner.
struct TracksRadioArt: View {
    let side: CGFloat
    var isLive = false
    /// Playing for the road: the car takes the radio waves' place.
    var isDriving = false
    /// A line under the name: what it's tuned to. Only where the artwork is big enough to read.
    var caption: String?
    /// Room at the bottom trailing corner for a button laid over the artwork.
    var leavesRoomForMenu = false

    /// Tracks’ red, the same in light and dark: artwork doesn't change with the appearance,
    /// as album covers don't. The accent lightens in dark mode, and white type on it wouldn't hold.
    static let color = Color(.displayP3, red: 0.84, green: 0.10, blue: 0.38)

    var body: some View {
        let inset = side * 0.075
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Self.color.gradient)
            // A little depth toward the bottom, where the name sits.
            LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: isDriving ? "car.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: side * 0.085, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Spacer()
                    if isLive {
                        PlayingWaveform(isActive: true, color: .white)
                            .font(.system(size: side * 0.075, weight: .semibold))
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
                Text(verbatim: "Tracks\nRadio")
                    .font(.system(size: side * 0.16, weight: .heavy))
                    .tracking(-side * 0.002)
                    .lineSpacing(-side * 0.03)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                if let caption {
                    Text(caption)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 4)
                        .padding(.trailing, leavesRoomForMenu ? 40 : 0)
                        .contentTransition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .padding(inset)
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: CoverImage.radius(for: side), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CoverImage.radius(for: side), style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 1)
        }
        .animation(.snappy, value: isLive)
        .animation(.snappy, value: isDriving)
        .accessibilityHidden(true)
    }
}

/// Tracks Radio at the head of Suggested Songs: its artwork, square, as tall as the songs beside
/// it. A tap plays it or pauses it; its menu tunes it.
struct TracksRadioTile: View {
    let side: CGFloat
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.radioTuningKey) private var storedTuning = ""
    @State private var showsTuner = LaunchScene.opensRadioTuner

    var body: some View {
        let isOn = player.isPlayingTracksRadio
        let tuning = RadioTuning(stored: storedTuning)
        let caption = player.isRadioDriving ? String(localized: "Driving · \(tuning.shortSummary)") : tuning.shortSummary
        Button {
            if isOn { player.togglePlayPause() } else { player.playTracksRadio() }
        } label: {
            TracksRadioArt(side: side, isLive: isOn && player.isPlaying, isDriving: player.isRadioDriving, caption: caption, leavesRoomForMenu: true)
        }
        .buttonStyle(.pressable)
        .overlay(alignment: .bottomTrailing) {
            RadioMenuButton(showsTuner: $showsTuner)
                .padding(side * 0.075 - 12)
        }
        .contextMenu { RadioMenuItems(showsTuner: $showsTuner) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Tracks Radio, \(caption)"))
        .accessibilityHint(isOn ? (player.isPlaying ? "Pauses your station" : "Resumes your station") : "Plays your station")
        .accessibilityAction(named: "Tune Tracks Radio") { showsTuner = true }
        .sheet(isPresented: $showsTuner) { RadioTunerSheet() }
    }
}

/// The "…" on the station's artwork: white on its colour, as controls on a coloured field are.
private struct RadioMenuButton: View {
    @Binding var showsTuner: Bool

    var body: some View {
        Menu {
            RadioMenuItems(showsTuner: $showsTuner)
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.22), in: .circle)
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .iconMenuStyle()
        .accessibilityLabel("More")
    }
}

/// What can be done with Tracks Radio from its menu.
private struct RadioMenuItems: View {
    @Binding var showsTuner: Bool
    @Environment(PlayerModel.self) private var player

    var body: some View {
        if player.isPlayingTracksRadio {
            Button(player.isPlaying ? "Pause" : "Resume", systemImage: player.isPlaying ? "pause" : "play") { player.togglePlayPause() }
        } else {
            Button("Play Tracks Radio", systemImage: "play") { player.playTracksRadio() }
        }
        Button("Tune Tracks Radio…", systemImage: "slider.horizontal.3") { showsTuner = true }
    }
}

/// Tracks Radio where there's no shelf of songs beside it: its artwork, what it's tuned to, and
/// Play and Tune, as a station's page opens in Music.
struct TracksRadioRow: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.radioTuningKey) private var storedTuning = ""
    @State private var showsTuner = false
    @ScaledMetric(relativeTo: .title3) private var side: CGFloat = 128

    var body: some View {
        let isOn = player.isPlayingTracksRadio
        let tuning = RadioTuning(stored: storedTuning)
        HStack(alignment: .center, spacing: 16) {
            Button {
                if isOn { player.togglePlayPause() } else { player.playTracksRadio() }
            } label: {
                TracksRadioArt(side: min(side, 180), isLive: isOn && player.isPlaying, isDriving: player.isRadioDriving)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Tracks Radio")

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.isRadioDriving ? "Driving" : "Your Station")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text("Tracks Radio")
                        .font(.title3.bold())
                    Text(tuning.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button {
                        if isOn { player.togglePlayPause() } else { player.playTracksRadio() }
                    } label: {
                        Label(isOn && player.isPlaying ? "Pause" : "Play", systemImage: isOn && player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.glassProminent)
                    Button("Tune…") { showsTuner = true }
                        .buttonStyle(.glass)
                }
                .buttonBorderShape(.capsule)
                .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsTuner) { RadioTunerSheet() }
    }
}

// MARK: - Tuning

/// Tuning Tracks Radio, as a sheet from its artwork, the crate, or the Mac's Play settings.
///
/// On iPhone the tuner in a navigation stack, with Done in its bar. On the Mac the tuner
/// carries its own title and a Done at its foot, as Mac sheets do.
struct RadioTunerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        RadioTuner()
        #else
        NavigationStack {
            RadioTuner()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        #endif
    }
}

/// How far Tracks Radio strays, the genres it leans into, and whether old favorites come back,
/// as a list of settings. Changes apply as they're made, from the next song if it's playing.
///
/// On iPhone it's a page, pushed in Settings or shown in the sheet, and its genres push a page
/// of their own. On the Mac it's the whole sheet, with the genres as checkboxes in place, since
/// nothing pushes inside a Mac sheet.
struct RadioTuner: View {
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.radioTuningKey) private var storedTuning = ""
    @AppStorage(PlayPreferences.radioFollowsTimeKey) private var followsTime = true
    @AppStorage(PlayPreferences.radioDayKey) private var storedDay = ""
    #if os(iOS)
    @AppStorage(PlayPreferences.radioNoticesDrivingKey) private var noticesDriving = true
    @Environment(\.openURL) private var openURL
    #if DEBUG
    /// `-TracksRadioTunerAnchor day` opens the tuner on Through the Day, for screenshots.
    @State private var opensDay = UserDefaults.standard.string(forKey: "TracksRadioTunerAnchor") == "day"
    #endif
    #endif
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDay = false
    #endif

    var body: some View {
        content
    }

    /// The genres to offer: the ones you play most, kept ready by the app so they're here as
    /// the tuner opens, and any picked that have since dropped out of the top.
    private var genres: [String] {
        let found = player.radioGenres
        let picked = RadioTuning(stored: storedTuning).genres.sorted()
        return found + picked.filter { !found.contains($0) }
    }

    #if os(iOS)
    private var content: some View {
        let tuning = RadioTuning(stored: storedTuning)
        return ScrollViewReader { proxy in form(tuning, proxy: proxy) }
            .navigationTitle("Tune Tracks Radio")
            .toolbarTitleDisplayMode(.inline)
    }

    private func form(_ tuning: RadioTuning, proxy: ScrollViewProxy) -> some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    TracksRadioArt(side: 120, isLive: player.isPlayingTracksRadio && player.isPlaying, isDriving: player.isRadioDriving)
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    VStack(spacing: 2) {
                        Text("Tracks Radio")
                            .font(.title2.bold())
                        Text(tuning.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .contentTransition(.opacity)
                        if player.isRadioDriving {
                            Label("Playing for the Road", systemImage: "car.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                                .padding(.top, 4)
                                .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)

            Section {
                discoveryPicker
                    .pickerStyle(.inline)
                    .labelsHidden()
            } header: {
                Text("Discovery")
            }

            Section {
                NavigationLink {
                    RadioGenresPage(genres: genres)
                } label: {
                    LabeledContent("Genres", value: tuning.genres.isEmpty ? String(localized: "Everything") : tuning.genreList)
                }
                Toggle("Bring Back Old Favorites", isOn: oldFavorites)
            } footer: {
                Text("Old favorites are songs you haven’t played in a few months. They come round more often.")
            }

            Section {
                Toggle("Follow the Time of Day", isOn: followsTimeBinding)
                if followsTime {
                    NavigationLink {
                        ThroughTheDayPage()
                    } label: {
                        LabeledContent("Through the Day", value: RadioDayWords.value(RadioDay(stored: storedDay)))
                    }
                }
                Toggle("Notice When You’re Driving", isOn: noticesDrivingBinding)
                if noticesDriving, player.drive.access == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Turn On Motion & Fitness") { openURL(settings) }
                }
            } header: {
                Text("Time and Driving")
                    .id(Self.momentsID)
            } footer: {
                Text(RadioMomentWords.footer(followsTime: followsTime, day: RadioDay(stored: storedDay), noticesDriving: noticesDriving, access: player.drive.access))
                    .contentTransition(.opacity)
            }

            if !player.isPlayingTracksRadio {
                Section {
                    Button("Play Tracks Radio") { player.playTracksRadio() }
                }
            }

            if tuning != .standard {
                Section {
                    Button("Reset to Balanced") { update { $0 = .standard } }
                }
            }
        }
        #if DEBUG
        // -TracksRadioTunerAnchor moments opens the tuner at Time and Driving, for screenshots.
        .task {
            guard UserDefaults.standard.string(forKey: "TracksRadioTunerAnchor") == "moments" else { return }
            try? await Task.sleep(for: .seconds(1))
            proxy.scrollTo(Self.momentsID, anchor: .top)
        }
        .navigationDestination(isPresented: $opensDay) { ThroughTheDayPage() }
        #endif
    }

    private static let momentsID = "moments"
    #endif

    #if os(macOS)
    private var content: some View {
        let tuning = RadioTuning(stored: storedTuning)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                TracksRadioArt(side: 56, isLive: player.isPlayingTracksRadio && player.isPlaying, isDriving: player.isRadioDriving)
                VStack(alignment: .leading, spacing: SettingsSpacing.tight) {
                    Text("Tune Tracks Radio")
                        .font(.title2.bold())
                    Text(tuning.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    discoveryPicker
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                } header: {
                    Text("Discovery")
                }

                Section {
                    SettingsDetailRow(title: Text("Leaning Into"), detail: genresDetail(tuning)) {
                        if !tuning.genres.isEmpty {
                            Button("Clear") { update { $0.genres = [] } }
                        }
                    }
                    if !genres.isEmpty {
                        genreChecks(tuning)
                    }
                } header: {
                    Text("Genres")
                } footer: {
                    Text(genres.isEmpty
                        ? "Genres show up here as Tracks learns them from what you play."
                        : "Tracks Radio plays more of the genres you pick, and less of everything else. Nothing is left out.")
                }

                Section {
                    SettingsSwitch(
                        "Bring Back Old Favorites",
                        detail: Text("Songs you haven’t played in a few months come round more often."),
                        isOn: oldFavorites
                    )
                    SettingsSwitch(
                        "Follow the Time of Day",
                        detail: Text(RadioMomentWords.timeDetail(followsTime)),
                        isOn: followsTimeBinding
                    )
                    if followsTime {
                        SettingsDetailRow(title: Text("Through the Day"), detail: Text(RadioDayWords.summary(RadioDay(stored: storedDay)))) {
                            Button("Customize…") { showsDay = true }
                                // Anchored to its row, rather than a second sheet over this one.
                                .popover(isPresented: $showsDay, arrowEdge: .trailing) { ThroughTheDaySheet() }
                        }
                    }
                }
            }
            .settingsPane()

            HStack(spacing: SettingsSpacing.standard) {
                if tuning != .standard {
                    Button("Reset to Balanced") { update { $0 = .standard } }
                }
                Spacer()
                if !player.isPlayingTracksRadio {
                    Button("Play Tracks Radio") { player.playTracksRadio() }
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            // The form ends in its own inset, so the bar needs none above it.
            .padding([.horizontal, .bottom], 20)
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: tuning.genres.isEmpty)
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: followsTime)
        // Changes apply as they're made, so Escape has nothing to undo: it closes, as Done does.
        .onExitCommand { dismiss() }
        #if DEBUG
        .onAppear(perform: PlaySettingsScreenshot.applyAppearance)
        #endif
    }

    private func genresDetail(_ tuning: RadioTuning) -> Text {
        tuning.genres.isEmpty
            ? Text("Everything, as you play it. Pick genres to hear more of them.")
            : Text(tuning.genres.sorted().formatted(.list(type: .and)))
    }

    /// Every genre offered, as checkboxes in three columns: picked in place, rather than on a
    /// page of their own.
    private func genreChecks(_ tuning: RadioTuning) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .leading), count: 3), alignment: .leading, spacing: 8) {
            ForEach(genres, id: \.self) { genre in
                Toggle(genre, isOn: Binding(
                    get: { tuning.genres.contains(genre) },
                    set: { isOn in update { if isOn { $0.genres.insert(genre) } else { $0.genres.remove(genre) } } }
                ))
                .toggleStyle(.checkbox)
                .lineLimit(1)
                .help(genre)
            }
        }
        .padding(.vertical, 4)
    }
    #endif

    private var discoveryPicker: some View {
        let tuning = RadioTuning(stored: storedTuning)
        return Picker("Discovery", selection: Binding(get: { tuning.discovery }, set: { value in update { $0.discovery = value } })) {
            ForEach(RadioTuning.Discovery.allCases) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                    Text(option.detail)
                        #if os(macOS)
                        .font(.caption)
                        #else
                        .font(.subheadline)
                        #endif
                        .foregroundStyle(.secondary)
                }
                .tag(option)
            }
        }
    }

    /// Makes the radio playing follow the change from its next song.
    private var followsTimeBinding: Binding<Bool> {
        Binding(
            get: { followsTime },
            set: { value in
                withAnimation(.snappy) { followsTime = value }
                Task { await player.retuneTracksRadio() }
            }
        )
    }

    #if os(iOS)
    /// Turned off, stops noticing at once. Turned on, Motion & Fitness is asked for only as
    /// the radio next starts, or now if it's playing.
    private var noticesDrivingBinding: Binding<Bool> {
        Binding(
            get: { noticesDriving },
            set: { value in
                withAnimation(.snappy) { noticesDriving = value }
                if !value { player.drive.stopIfUnneeded() }
                Task { await player.retuneTracksRadio() }
            }
        )
    }
    #endif

    private var oldFavorites: Binding<Bool> {
        Binding(
            get: { RadioTuning(stored: storedTuning).bringsBackOldFavorites },
            set: { value in update { $0.bringsBackOldFavorites = value } }
        )
    }

    private func update(_ change: (inout RadioTuning) -> Void) {
        var tuning = RadioTuning(stored: storedTuning)
        change(&tuning)
        withAnimation(.snappy) { storedTuning = tuning.stored }
        Task { await player.retuneTracksRadio() }
    }
}

#if os(iOS)
/// The genres Tracks Radio leans into, picked from the ones you play most. None picked plays
/// across everything.
private struct RadioGenresPage: View {
    let genres: [String]
    @Environment(PlayerModel.self) private var player
    @AppStorage(PlayPreferences.radioTuningKey) private var storedTuning = ""

    var body: some View {
        let tuning = RadioTuning(stored: storedTuning)
        List {
            Section {
                row(String(localized: "Everything"), isChecked: tuning.genres.isEmpty) {
                    update { $0.genres = [] }
                }
            }
            Section {
                ForEach(genres, id: \.self) { genre in
                    row(genre, isChecked: tuning.genres.contains(genre)) {
                        update { tuning in
                            if tuning.genres.contains(genre) { tuning.genres.remove(genre) } else { tuning.genres.insert(genre) }
                        }
                    }
                }
            } header: {
                Text("Your Genres")
            } footer: {
                Text("Tracks Radio plays more of the genres you pick, and less of everything else. Nothing is left out.")
            }
        }
        .overlay {
            if genres.isEmpty {
                ContentUnavailableView("No Genres Yet", systemImage: "guitars", description: Text("Genres show up here as Tracks learns them from what you play."))
            }
        }
        .navigationTitle("Genres")
        .toolbarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, isChecked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }

    private func update(_ change: (inout RadioTuning) -> Void) {
        var tuning = RadioTuning(stored: storedTuning)
        change(&tuning)
        storedTuning = tuning.stored
        Task { await player.retuneTracksRadio() }
    }
}
#endif

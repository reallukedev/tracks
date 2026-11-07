import SwiftUI
import TracksCore

extension PlaySection {
    var title: LocalizedStringKey {
        switch self {
        case .suggestedSongs: "Suggested Songs"
        case .suggestedArtists: "Suggested Artists"
        case .forYou: "For You"
        case .recentlyPlayed: "Recently Played"
        case .yourArtists: "Your Artists"
        case .moods: "Find Your Mood"
        case .genres: "Genres"
        case .newReleases: "New from Your Artists"
        case .charts: "Top Charts"
        case .mixes: "Made from Your Listening"
        case .radio: "Radio"
        case .library: "Library"
        case .appleMusic: "Picks from Apple Music"
        }
    }

    /// What's in it, for the row under its name. Tracks Radio leads the crate, and leads
    /// Suggested Songs only while the crate is hidden, so that row says so only then.
    func detail(in layout: PlayLayout) -> LocalizedStringKey {
        switch self {
        case .suggestedSongs:
            layout.isVisible(.forYou)
                ? "Songs you’ve never played, picked for you"
                : "Tracks Radio, and songs you’ve never played"
        case .suggestedArtists: "Like your favorites, but new to you"
        case .forYou: "This hour’s mix, Tracks Radio and more, to flip through"
        case .recentlyPlayed: "Albums, playlists and stations"
        case .yourArtists: "The artists you play most lately"
        case .moods: "Handpicked, Feel Good, Chill and more"
        case .genres: "Pop, Hip-Hop, Rock and more, yours first"
        case .newReleases: "New albums and singles, and what’s coming"
        case .charts: "Apple Music’s most played"
        case .mixes: "On Repeat, Deep Cuts, Radio Finds and more"
        case .radio: "Live radio and your stations"
        case .library: "Playlists, albums, artists and songs"
        case .appleMusic: "Apple Music’s recommendations"
        }
    }

    var symbol: String {
        switch self {
        case .suggestedSongs: "sparkles"
        case .suggestedArtists: "person.crop.circle.badge.plus"
        case .forYou: "star.square.on.square"
        case .recentlyPlayed: "clock"
        case .yourArtists: "person.2"
        case .moods: "face.smiling"
        case .genres: "guitars"
        case .newReleases: "calendar.badge.plus"
        case .charts: "chart.line.uptrend.xyaxis"
        case .mixes: "square.grid.2x2"
        case .radio: "dot.radiowaves.left.and.right"
        case .library: "music.note.list"
        case .appleMusic: "music.note"
        }
    }

    /// Whether this platform's Play shows the section at all. The Mac's library is in the
    /// sidebar, so Listen Now never shows it and there's nothing to arrange.
    var isOffered: Bool {
        #if os(macOS)
        self != .library
        #else
        true
        #endif
    }
}

extension PlaySection {
    /// What the section is called with this source on. Your own music's Play follows the same
    /// layout as Apple Music's, with its own music where Apple's would be.
    func title(for source: MusicSource) -> LocalizedStringKey {
        guard source == .yourMusic else { return title }
        switch self {
        case .newReleases: return "Waiting to Be Heard"
        case .charts: return "From Your Downloads"
        case .appleMusic: return "Picked for You"
        default: return title
        }
    }

    func detail(in layout: PlayLayout, for source: MusicSource) -> LocalizedStringKey {
        guard source == .yourMusic else { return detail(in: layout) }
        switch self {
        case .suggestedSongs:
            return layout.isVisible(.forYou)
                ? "Songs your server finds that you’ve never played"
                : "Tracks Radio, and songs your server finds"
        case .recentlyPlayed: return "Albums of yours you’ve played lately"
        case .genres: return "The genres in your music, the most played first"
        case .newReleases: return "Songs of yours you’ve never played"
        case .charts: return "Songs you can play without a connection"
        case .library: return "Playlists, artists, albums, songs and downloads"
        case .appleMusic: return "What your servers pick for you, and their shelves"
        default: return detail(in: layout)
        }
    }

    func symbol(for source: MusicSource) -> String {
        guard source == .yourMusic else { return symbol }
        switch self {
        case .newReleases: return "hourglass"
        case .charts: return "arrow.down.circle"
        case .appleMusic: return "sparkles.rectangle.stack"
        default: return symbol
        }
    }

    /// Whether Play shows the section with this source on: your own music has no suggested
    /// artists or live radio from Apple Music.
    func isOffered(for source: MusicSource) -> Bool {
        guard isOffered else { return false }
        return source == .appleMusic || (self != .suggestedArtists && self != .radio)
    }
}

extension PlayLayout {
    /// The sections this platform offers, in the chosen order.
    var offered: [PlaySection] { order.filter(\.isOffered) }

    /// The sections offered with this source on, in the chosen order.
    func offered(for source: MusicSource) -> [PlaySection] { order.filter { $0.isOffered(for: source) } }
}

/// Editing Play's sections, as a sheet: over the Play tab when launched with `-TracksEditPlay`,
/// and from the Mac's Play settings as "Edit Listen Now…". On iPhone it's also a page in
/// Settings ▸ Play.
struct PlayLayoutEditor: View {
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @AppStorage(PlayPreferences.layoutKey) private var storedLayout = ""
    #endif

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SettingsSpacing.tight) {
                Text("Edit Listen Now")
                    .font(.title2.bold())
                Text("Choose the sections Listen Now shows. Drag to change their order.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            PlayLayoutList()
                .padding(.horizontal, 20)

            HStack(spacing: SettingsSpacing.standard) {
                if !storedLayout.isEmpty {
                    Button("Restore Default Layout") { storedLayout = "" }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 460)
        // Each change is kept as it's made, so Escape closes, as Done does.
        .onExitCommand { dismiss() }
        #if DEBUG
        .onAppear(perform: PlaySettingsScreenshot.applyAppearance)
        #endif
        #else
        NavigationStack {
            PlayLayoutList()
                .navigationTitle("Edit Play")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        #endif
    }
}

/// Which sections the Play tab shows, in what order. Like Music's Library edit: drag to
/// reorder, a switch to show or hide. In the sheet, and in Settings.
struct PlayLayoutList: View {
    @AppStorage(PlayPreferences.layoutKey) private var storedLayout = ""
    @Environment(AppModel.self) private var model

    #if os(macOS)
    /// Every row is this tall, so the list's height comes from its rows rather than from
    /// anything measured.
    private static let rowHeight: CGFloat = 40
    #endif

    /// Kept as the layout it stands for, and stored empty while it's the standard one, so a
    /// later update's new sections land where they belong.
    private var layout: Binding<PlayLayout> {
        Binding(
            get: { PlayLayout(stored: storedLayout) },
            set: { storedLayout = $0 == .standard ? "" : $0.stored }
        )
    }

    var body: some View {
        let current = layout.wrappedValue
        let sections = current.offered(for: model.musicSource)
        List {
            Section {
                ForEach(sections) { section in
                    row(section, in: current)
                }
                .onMove { offsets, destination in
                    move(offsets, to: destination, among: sections)
                }
            } footer: {
                #if os(iOS)
                Text("Drag to change the order. Hidden sections keep their place for when you turn them back on.")
                #endif
            }

            #if os(iOS)
            if current != .standard {
                Section {
                    Button("Restore Default Layout") { layout.wrappedValue = .standard }
                }
            }
            #endif
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #else
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: CGFloat(sections.count) * Self.rowHeight + 8)
        // A grouped form's section, rather than a ruled box.
        .background(.fill.quinary, in: .rect(cornerRadius: 10, style: .continuous))
        #endif
    }

    private func row(_ section: PlaySection, in current: PlayLayout) -> some View {
        let isVisible = Binding(
            get: { current.isVisible(section) },
            set: { layout.wrappedValue[isVisible: section] = $0 }
        )
        #if os(macOS)
        return HStack(spacing: SettingsSpacing.row) {
            Image(systemName: section.symbol(for: model.musicSource))
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title(for: model.musicSource))
                Text(section.detail(in: current, for: model.musicSource))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(section.title(for: model.musicSource), isOn: isVisible)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .frame(height: Self.rowHeight - 8)
        .opacity(current.isVisible(section) ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Drag to change the order."))
        #else
        return Toggle(isOn: isVisible) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title(for: model.musicSource))
                    Text(section.detail(in: current, for: model.musicSource))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: section.symbol(for: model.musicSource))
                    .foregroundStyle(.tint)
            }
        }
        #endif
    }

    /// A move among the sections shown, made in the whole order: sections this platform
    /// doesn't offer keep their places around it.
    private func move(_ offsets: IndexSet, to destination: Int, among sections: [PlaySection]) {
        let order = layout.wrappedValue.order
        let from = IndexSet(offsets.compactMap { order.firstIndex(of: sections[$0]) })
        let to = destination < sections.count ? order.firstIndex(of: sections[destination]) ?? order.count : order.count
        layout.wrappedValue.move(from: from, to: to)
    }
}

import SwiftUI
import TracksCore

/// Makes a smart playlist, or changes one's rules: where its songs come from, what they have to
/// be, in what order, and how many. Shows how many songs fit as the rules are written.
struct SmartPlaylistEditor: View {
    /// The playlist whose rules these are, or `nil` for a new one.
    let playlistID: UUID?
    var onCreate: (UUID) -> Void = { _ in }
    @Environment(YourMusic.self) private var music
    @Environment(PlayFeed.self) private var feed
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var rules = SmartRules(conditions: [SmartRules.Condition(field: .artist)])
    @State private var isLimited = false
    @State private var limit = 25

    var body: some View {
        let matching = matchCount
        NavigationStack {
            Form {
                Section {
                    TextField("Playlist Name", text: $name)
                }

                Section {
                    Picker("Songs From", selection: $rules.source) {
                        Text("Downloaded").tag(SmartRules.Source.downloaded)
                        Text("All Your Music").tag(SmartRules.Source.yourMusic)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    #if os(macOS)
                    Text(rules.source == .downloaded
                         ? "Songs on this Mac: your files and what you've downloaded. They play with no connection."
                         : "Everything in your music, on this Mac and on your servers.")
                    #else
                    Text(rules.source == .downloaded
                         ? "Songs on this iPhone: your files and what you've downloaded. They play with no connection."
                         : "Everything in your music, on this iPhone and on your servers.")
                    #endif
                }

                Section {
                    if rules.conditions.count > 1 {
                        Picker("Match", selection: $rules.match) {
                            Text("All Rules").tag(SmartRules.Match.all)
                            Text("Any Rule").tag(SmartRules.Match.any)
                        }
                    }
                    ForEach($rules.conditions) { $condition in
                        ConditionEditor(condition: $condition)
                    }
                    .onDelete { rules.conditions.remove(atOffsets: $0) }
                    Button("Add Rule", systemImage: "plus.circle.fill") {
                        withAnimation(.snappy) { rules.conditions.append(SmartRules.Condition(field: .artist)) }
                    }
                } header: {
                    Text("Rules")
                } footer: {
                    if rules.conditions.isEmpty {
                        Text("With no rules, every song fits.")
                    }
                }

                Section {
                    Picker("Order", selection: $rules.order) {
                        ForEach(SmartRules.Order.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Limit", isOn: $isLimited.animation(.snappy))
                    if isLimited {
                        Stepper(value: $limit, in: 5...1_000, step: 5) {
                            Text("^[\(limit) song](inflect: true)")
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("^[\(matching) song](inflect: true) fit right now. It changes as your music and plays do.")
                        .contentTransition(.numericText())
                        .animation(.snappy, value: matching)
                }
            }
            .navigationTitle(playlistID == nil ? "New Smart Playlist" : "Edit Rules")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(playlistID == nil ? "Create" : "Done", action: save)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private var finished: SmartRules {
        var finished = rules
        finished.limit = isLimited ? limit : nil
        return finished
    }

    private var matchCount: Int {
        finished.songs(from: music.tracks(for: rules.source), facts: feed.facts, seed: 0).count
    }

    private func fill() {
        guard let playlistID, let playlist = music.playlists.playlist(id: playlistID), let saved = playlist.rules else { return }
        name = playlist.name
        rules = saved
        isLimited = saved.limit != nil
        limit = saved.limit ?? 25
    }

    private func save() {
        // Rules left blank say nothing, so they're dropped rather than kept.
        var rules = finished
        rules.conditions.removeAll { !$0.isComplete }
        if let playlistID {
            music.playlists.update(playlistID) { playlist in
                playlist.rules = rules
                if !name.trimmingCharacters(in: .whitespaces).isEmpty { playlist.name = name }
            }
            dismiss()
        } else {
            let playlist = music.playlists.create(name: name, rules: rules)
            dismiss()
            onCreate(playlist.id)
        }
    }
}

/// One rule: what about a song, how it compares, and with what.
private struct ConditionEditor: View {
    @Binding var condition: SmartRules.Condition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Picker("Field", selection: fieldBinding) {
                    ForEach(SmartRules.Field.allCases) { Text($0.title).tag($0) }
                }
                Picker("Comparison", selection: $condition.comparison) {
                    ForEach(condition.field.comparisons) { Text($0.title).tag($0) }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            switch condition.field.kind {
            case .text:
                TextField(condition.field.placeholder, text: $condition.text)
                    .titleEntry()
                    .autocorrectionDisabled()
            case .number:
                TextField(condition.field.placeholder, value: $condition.number, format: .number.grouping(.never))
                    .numberEntry()
            case .days:
                Stepper(value: $condition.number, in: 1...3_650) {
                    Text("^[\(condition.number) day](inflect: true)")
                        .monospacedDigit()
                }
            case .quality:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    /// A new field starts over: its own comparisons and number.
    private var fieldBinding: Binding<SmartRules.Field> {
        Binding {
            condition.field
        } set: { field in
            guard field != condition.field else { return }
            let keepsText = field.kind == .text && condition.field.kind == .text
            condition = SmartRules.Condition(id: condition.id, field: field, text: keepsText ? condition.text : "")
        }
    }
}

extension SmartRules.Field {
    var title: LocalizedStringKey {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .genre: "Genre"
        case .year: "Year"
        case .plays: "Plays"
        case .lastPlayed: "Last Played"
        case .dateAdded: "Date Added"
        case .quality: "Quality"
        }
    }

    var placeholder: LocalizedStringKey {
        switch self {
        case .title: "Song Title"
        case .artist: "Artist Name"
        case .album: "Album Title"
        case .genre: "Genre"
        case .year: "Year"
        case .plays: "Plays"
        default: ""
        }
    }
}

extension SmartRules.Comparison {
    var title: LocalizedStringKey {
        switch self {
        case .contains: "contains"
        case .is: "is"
        case .isNot: "is not"
        case .doesNotContain: "does not contain"
        case .beginsWith: "begins with"
        case .atLeast: "is at least"
        case .atMost: "is at most"
        case .inTheLast: "is in the last"
        case .notInTheLast: "is not in the last"
        case .isLossless: "is Lossless"
        case .isHiRes: "is Hi-Res Lossless"
        case .isNotLossless: "is not Lossless"
        }
    }
}

extension SmartRules.Order {
    var title: LocalizedStringKey {
        switch self {
        case .random: "Random"
        case .mostPlayed: "Most Played"
        case .leastPlayed: "Least Played"
        case .recentlyPlayed: "Recently Played"
        case .recentlyAdded: "Recently Added"
        case .title: "Title"
        case .artist: "Artist"
        }
    }
}

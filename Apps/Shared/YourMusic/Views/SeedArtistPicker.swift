import SwiftUI
import TracksCore

/// The artists Picked for You starts from, chosen by searching your servers: what it needs
/// when there's no listening history or library to go on, and leads with when there is.
struct SeedArtistPicker: View {
    @Environment(YourMusic.self) private var music
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var found: [String] = []
    /// Nil until the sheet has read the saved picks.
    @State private var picked: [String]?

    var body: some View {
        let picks = picked ?? []
        NavigationStack {
            List {
                if !term.isEmpty {
                    Section("Artists") {
                        ForEach(candidates, id: \.self) { name in
                            let isPicked = picks.contains { StatsCalculator.folded($0) == StatsCalculator.folded(name) }
                            Button {
                                toggle(name)
                            } label: {
                                HStack {
                                    Text(name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if isPicked {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                            .fontWeight(.semibold)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .accessibilityAddTraits(isPicked ? .isSelected : [])
                        }
                    }
                }
                if !picks.isEmpty {
                    Section {
                        ForEach(picks, id: \.self) { name in
                            Text(name)
                        }
                        .onDelete { picked?.remove(atOffsets: $0) }
                    } header: {
                        Text("Your Picks")
                    } footer: {
                        Text("Picked for You starts from these, then from the artists you play most.")
                    }
                }
            }
            .overlay {
                if picks.isEmpty, term.isEmpty {
                    ContentUnavailableView(
                        "Artists You Like",
                        systemImage: "music.microphone",
                        description: Text("Search for a few, and your server finds songs by them and artists like them.")
                    )
                }
            }
            .searchable(text: $query, placement: .pageSearch(), prompt: "Artists")
            .navigationTitle("Choose Artists")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) {
                        music.discover.setPickedArtists(picks)
                        dismiss()
                    }
                }
            }
            .task(id: term) { await searchArtists() }
        }
        .onAppear {
            if picked == nil { picked = music.discover.pickedArtists }
        }
    }

    private var term: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// What the servers found, and what's typed, so an artist they don't know can still be picked.
    private var candidates: [String] {
        let key = StatsCalculator.folded(term)
        return found.contains { StatsCalculator.folded($0) == key } ? found : found + [term]
    }

    private func toggle(_ name: String) {
        let key = StatsCalculator.folded(name)
        if picked?.contains(where: { StatsCalculator.folded($0) == key }) == true {
            picked?.removeAll { StatsCalculator.folded($0) == key }
        } else {
            picked = (picked ?? []) + [name]
        }
    }

    /// Asks every connected server for artists by that name. Octo finds artists it doesn't
    /// have too, with no Last.fm key needed.
    private func searchArtists() async {
        guard !term.isEmpty else {
            found = []
            return
        }
        // A short pause so typing doesn't ask on every letter.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let clients = music.servers.onlineServers.compactMap { music.servers.client(for: $0.id) }
        let term = term
        let names = await withTaskGroup(of: [String].self) { group in
            for client in clients {
                group.addTask { (try? await client.search(term, artists: 10, albums: 0, songs: 0).artists.map(\.name)) ?? [] }
            }
            var names: [String] = []
            for await found in group { names += found }
            return names
        }
        guard !Task.isCancelled else { return }
        var seen = Set<String>()
        found = names.filter { seen.insert(StatsCalculator.folded($0)).inserted }
    }
}

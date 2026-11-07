#if DEBUG
import SwiftUI
import TracksCore

/// A model on sample data. The flag goes in a volatile domain, so it never reaches the real
/// app's defaults, and a preview never opens the real store.
@MainActor
private let partyPreviewModel: AppModel = {
    UserDefaults.standard.setVolatileDomain(["TracksDemoData": true], forName: UserDefaults.argumentDomain)
    return AppModel()
}()

/// Party in a stack, as Play pushes it, with everything the app hands its pages.
private struct PartyPreview: View {
    var vibe: PartyVibe = .danceFloor

    var body: some View {
        let model = partyPreviewModel
        NavigationStack {
            PartyView()
                .playDestinations()
        }
        .environment(model)
        .environment(model.player)
        .environment(model.playFeed)
        .environment(model.discovery)
        .environment(model.yourMusic)
        .environment(model.lidarr)
        .environment(model.playNavigator)
        .defaultAppStorage(defaults)
    }

    /// The party to open on, kept apart from the app's own choice.
    private var defaults: UserDefaults {
        let defaults = UserDefaults(suiteName: "PartyPreview.\(vibe.rawValue)") ?? .standard
        defaults.set(vibe.rawValue, forKey: PartyVibe.storageKey)
        return defaults
    }
}

#Preview("Dance Floor") { PartyPreview() }

#Preview("Dinner Party, dark") {
    PartyPreview(vibe: .dinnerParty)
        .preferredColorScheme(.dark)
}

#Preview("All Ages, AX5") {
    PartyPreview(vibe: .allAges)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Chips") {
    @Previewable @State var vibe = PartyVibe.backyard
    PartyVibeChips(selection: $vibe, vibes: PartyVibe.allCases)
        .padding(.vertical, 20)
        .background { PartyField(vibe: vibe) }
}
#endif

import SwiftUI
import TracksCore

/// Whether the statistics count Apple Music and Your Music apart, and which one is on show.
///
/// The choice is offered only once the setting is on and something has been played from Your
/// Music; until then everything counts together, whatever was chosen before.
struct SourceScopeSetting: DynamicProperty {
    @AppStorage(SourceScope.separatesKey) private var separates = false
    @AppStorage(SourceScope.storageKey) private var chosen: SourceScope = .all
    @Environment(AppModel.self) private var model

    var isOffered: Bool {
        separates && model.library.history.hasYourMusic
    }

    /// The plays to count.
    var scope: SourceScope {
        SourceScope.effective(chosen, separates: separates, hasYourMusic: model.library.history.hasYourMusic)
    }

    var selection: Binding<SourceScope> { $chosen }
}

extension SourceScope {
    var title: LocalizedStringKey {
        switch self {
        case .all: "All Music"
        case .appleMusic: "Apple Music"
        case .yourMusic: "Your Music"
        }
    }

    /// The same symbols as the music source's, so the two read as one idea.
    var symbol: String {
        switch self {
        case .all: "music.note.list"
        case .appleMusic: "music.note"
        case .yourMusic: "externaldrive.fill"
        }
    }

    /// Radio stations are Apple Music's, so their sessions count everywhere but Your Music.
    var includesStations: Bool { self != .yourMusic }

    /// The scope as plain text, for a subtitle. Empty for everything.
    var subtitle: String {
        switch self {
        case .all: ""
        case .appleMusic: String(localized: "Apple Music")
        case .yourMusic: String(localized: "Your Music")
        }
    }
}

/// All Music, Apple Music or Your Music, for a statistics page's toolbar. A pop-up on the Mac;
/// on iPhone a menu whose symbol is the scope on show.
struct SourceScopeMenu: View {
    @Binding var scope: SourceScope

    var body: some View {
        #if os(macOS)
        picker
            .pickerStyle(.menu)
            .fixedSize()
            .help("Count all your music, or Apple Music or Your Music alone")
        #else
        Menu {
            picker
        } label: {
            Label("Music", systemImage: scope.symbol)
        }
        #endif
    }

    private var picker: some View {
        Picker("Music", selection: $scope) {
            ForEach(SourceScope.allCases) { scope in
                Label(scope.title, systemImage: scope.symbol).tag(scope)
            }
        }
    }
}

extension View {
    /// On iPhone, names the scope under the title while it isn't everything. The Mac's pop-up
    /// already shows it.
    func sourceScopeSubtitle(_ scope: SourceScope) -> some View {
        #if os(iOS)
        navigationSubtitle(scope.subtitle)
        #else
        self
        #endif
    }
}

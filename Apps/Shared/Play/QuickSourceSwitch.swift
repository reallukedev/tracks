import SwiftUI
import AppIntents
import MusicKit
import TracksCore

/// Quick Switch: moving between Apple Music and your own music from the Play tab, for someone
/// who uses both, each for its own times. Off by default, and only offered with both there.
/// What's playing carries on through a switch, until something from the other is played.
enum QuickSwitch {
    static let storageKey = "quickSourceSwitch"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: storageKey) }

    /// Both are there to switch between: Apple Music allowed, and music of your own. Sample
    /// data has both.
    @MainActor
    static func isAvailable(_ music: YourMusic) -> Bool {
        (MusicAuthorization.currentStatus == .authorized || music.isDemo) && music.hasMusic
    }
}

extension View {
    /// Play's title as a menu of the two sources, with the one playing under it, and a word
    /// when the other would do better right now: offline, your downloads; your server not
    /// answering, Apple Music.
    func quickSourceSwitch() -> some View {
        modifier(QuickSourceSwitch())
    }
}

private struct QuickSourceSwitch: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(YourMusic.self) private var music
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(QuickSwitch.storageKey) private var isOn = false

    func body(content: Content) -> some View {
        if isOn, QuickSwitch.isAvailable(music) {
            content
                .navigationSubtitle(model.musicSource.name)
                .toolbarTitleMenu { picker }
                #if os(iOS)
                // At the top of the page the title is large, and the system gives a large
                // title no menu: the source under it opens the same one, so switching is a tap
                // away however far up the page is, the search field showing or not.
                .toolbar {
                    ToolbarItem(placement: .largeSubtitle) {
                        Menu { picker } label: { LargeSourceLabel(source: model.musicSource) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Music Source")
                            .accessibilityValue(model.musicSource.name)
                            .accessibilityHint("Switches between Apple Music and your music")
                    }
                }
                #endif
                .safeAreaInset(edge: .bottom) {
                    if let suggestion {
                        SwitchSuggestion(suggestion: suggestion) { model.switchSource(to: suggestion.source) }
                            .padding(.bottom, 8)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: suggestion?.source)
                .sensoryFeedback(.success, trigger: model.musicSource)
        } else {
            content
        }
    }

    private var picker: some View {
        Picker("Music Source", selection: Binding(get: { model.musicSource }, set: { model.switchSource(to: $0) })) {
            ForEach(MusicSource.allCases) { source in
                Label(source.title, systemImage: source.symbol).tag(source)
            }
        }
    }

    /// The other source, when it'd play where this one can't.
    private var suggestion: SwitchSuggestion.Suggestion? {
        let downloaded = music.tracks(for: .downloaded)
        switch model.musicSource {
        case .appleMusic where !music.network.isOnline && !downloaded.isEmpty:
            return .init(source: .yourMusic, reason: String(localized: "You're offline"), action: String(localized: "Play Your Downloads"))
        case .yourMusic where music.network.isOnline && downloaded.isEmpty && serversAreDown:
            return .init(source: .appleMusic, reason: String(localized: "Your server isn't answering"), action: String(localized: "Switch to Apple Music"))
        default:
            return nil
        }
    }

    /// Every server has been tried and none answered: not just still connecting.
    private var serversAreDown: Bool {
        let servers = music.servers.servers
        return !servers.isEmpty && servers.allSatisfy { server in
            switch music.servers.status[server.id] {
            case .offline, .failed, .wrongPassword: true
            default: false
            }
        }
    }
}

#if os(iOS)
/// The source under Play's large title, as its subtitle is drawn, with the chevron that says
/// it's a menu.
private struct LargeSourceLabel: View {
    let source: MusicSource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(source.name)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .imageScale(.small)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        // A finger's worth to tap, though the words are small.
        .frame(minHeight: 28)
        .contentShape(.rect)
        .contentTransition(.opacity)
    }
}
#endif

/// A small word at the foot of Play, offering the other source.
private struct SwitchSuggestion: View {
    struct Suggestion: Equatable {
        let source: MusicSource
        let reason: String
        let action: String
    }

    let suggestion: Suggestion
    let switchSource: () -> Void

    var body: some View {
        Button(action: switchSource) {
            HStack(spacing: 10) {
                Image(systemName: suggestion.source.symbol)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(suggestion.action)
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Focus and Shortcuts

extension MusicSource: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music Source"

    static let caseDisplayRepresentations: [MusicSource: DisplayRepresentation] = [
        .appleMusic: DisplayRepresentation(title: "Apple Music", image: .init(systemName: "music.note")),
        .yourMusic: DisplayRepresentation(title: "Your Music", subtitle: "Your files and your servers", image: .init(systemName: "externaldrive.fill")),
    ]
}

/// A Focus filter: which music Play plays while a Focus is on, as Apple Music at the gym and
/// your own lossless files at your desk. When the Focus ends, it goes back to what it was.
struct MusicSourceFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Music Source"
    static let description = IntentDescription("Choose which music source Play uses while this Focus is on.")

    @Parameter(title: "Music Source")
    var source: MusicSource?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(source?.name ?? String(localized: "Unchanged"))")
    }

    private static let beforeFocusKey = "musicSourceBeforeFocus"

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = AppModel.shared
        let defaults = UserDefaults.standard
        if let source {
            // The first Focus to change it remembers what to go back to.
            if defaults.string(forKey: Self.beforeFocusKey) == nil {
                defaults.set(model.musicSource.rawValue, forKey: Self.beforeFocusKey)
            }
            model.switchSource(to: source)
        } else if let before = defaults.string(forKey: Self.beforeFocusKey).flatMap(MusicSource.init(rawValue:)) {
            // The Focus ended, or stopped choosing: back to what it was.
            defaults.removeObject(forKey: Self.beforeFocusKey)
            model.switchSource(to: before)
        }
        return .result()
    }
}

/// Switches Play between Apple Music and your own music, from Shortcuts or the Action button,
/// without stopping what's playing.
struct SwitchMusicSourceIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Music Source"
    static let description = IntentDescription("Switches between your music sources. The song playing carries on from the other source when it has it. Leave the source empty to switch to whichever isn't on.")

    @Parameter(title: "Music Source")
    var source: MusicSource?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let target = source ?? (model.musicSource == .appleMusic ? .yourMusic : .appleMusic)
        guard target != model.musicSource else { return .result(dialog: "Already playing from \(target.name).") }
        if target == .appleMusic, !model.isDemoLaunch, MusicAuthorization.currentStatus != .authorized {
            throw PlayIntentError.appleMusicAccess
        }
        if await model.switchSourceCarryingOn(to: target) {
            return .result(dialog: "Now playing from \(target.name).")
        }
        return .result(dialog: "Switched to \(target.name).")
    }
}

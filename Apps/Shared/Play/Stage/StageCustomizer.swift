import SwiftUI

/// Stage's choices: how it's laid out, how the visualizer draws, what's behind, and what's
/// shown. On iPhone it's a half-height sheet, so Stage changes above it as you choose.
struct StageCustomizer: View {
    @AppStorage(StageLayout.storageKey) private var layout = StageLayout.cover
    @AppStorage(StageVisualizer.storageKey) private var visualizer = StageVisualizer.bars
    @AppStorage(StageOption.background) private var background = StageBackground.living
    @AppStorage(LivingCoverOption.movesWithMusic) private var movesWithMusic = true
    @AppStorage(StageOption.showsAlbum) private var showsAlbum = true
    @AppStorage(StageOption.showsProgress) private var showsProgress = true
    @AppStorage(StageOption.showsNext) private var showsNext = true
    @AppStorage(StageOption.showsClock) private var showsClock = false
    @AppStorage(StageOrientation.storageKey) private var orientation = StageOrientation.landscape
    @AppStorage(StageOption.keepsScreenOn) private var keepsScreenOn = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Layout") {
                    LayoutChooser(selection: $layout)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                }
                Section {
                    // A pop-up row, as Background's: five choices don't fit side by side.
                    Picker("Visualizer", selection: $visualizer) {
                        ForEach(StageVisualizer.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Visualizer")
                } footer: {
                    Text(visualizer.footer)
                }
                Section {
                    Picker("Background", selection: $background) {
                        ForEach(StageBackground.allCases) { Text($0.title).tag($0) }
                    }
                    if background == .living {
                        Toggle("Move with the Music", isOn: $movesWithMusic)
                    }
                } header: {
                    Text("Background")
                } footer: {
                    if background == .living {
                        Text(PlaySettingsWords.livingCoverFooter(movesWithMusic: movesWithMusic))
                    } else {
                        Text(background.footer)
                    }
                }
                Section("Show") {
                    Toggle("Album", isOn: $showsAlbum)
                    Toggle("Progress", isOn: $showsProgress)
                    Toggle("Up Next", isOn: $showsNext)
                    if layout != .clock {
                        Toggle("Clock", isOn: $showsClock)
                    }
                }
                #if os(iOS)
                Section {
                    Picker("Orientation", selection: $orientation) {
                        ForEach(StageOrientation.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Keep Screen On", isOn: $keepsScreenOn)
                } header: {
                    Text("iPhone")
                } footer: {
                    Text(keepsScreenOn
                         ? "iPhone stays awake and bright while Stage is open, even with Rotation Lock on. What's on Stage shifts a few points now and then, too slowly to notice, so nothing stays burned in."
                         : "iPhone dims and locks as it usually does.")
                }
                #endif
            }
            .formStyle(.grouped)
            .navigationTitle("Customize Stage")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}

/// The four layouts as small tiles, each drawn with its symbol, the chosen one outlined.
private struct LayoutChooser: View {
    @Binding var selection: StageLayout

    var body: some View {
        HStack(spacing: 10) {
            ForEach(StageLayout.allCases) { layout in
                let isChosen = layout == selection
                Button {
                    selection = layout
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: layout.symbol)
                            .font(.title2)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 12, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isChosen ? Color.accentColor : .clear, lineWidth: 2)
                            }
                            .foregroundStyle(isChosen ? Color.accentColor : .secondary)
                        Text(layout.title)
                            .font(.caption.weight(isChosen ? .semibold : .regular))
                            .foregroundStyle(isChosen ? .primary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

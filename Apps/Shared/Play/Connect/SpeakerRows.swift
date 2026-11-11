import SwiftUI
import TracksCore

extension NearbySpeakers {
    /// "A Home's Pod", or "Kitchen and Living Room" for a group.
    var label: String { names.formatted(.list(type: .and)) }
}

extension NearbyDevices.Device {
    /// Its name, and where its sound is going when that isn't its own speakers: "Luke's
    /// iPhone · A Home's Pod".
    var nameWithSpeakers: String {
        guard let speakers = state?.speakers, state?.hasSong == true else { return name }
        return String(localized: "\(name) · \(speakers.label)")
    }
}

#if os(macOS)
/// Where the Mac's sound is going, as Control Center's Sound module names it, with the
/// system's AirPlay picker beside it. Tracks' own player plays wherever the Mac's sound goes.
struct SystemOutputRow: View {
    let name: String
    let speakers: NearbySpeakers?

    var body: some View {
        HStack(spacing: 10) {
            DeviceGlyph(symbol: speakers?.symbol ?? "speaker.wave.2.fill", isCurrent: speakers != nil)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            Text(name)
                .font(.callout)
                .lineLimit(1)
                .accessibilityLabel(Text("Sound Output"))
                .accessibilityValue(Text(name))
            Spacer(minLength: 8)
            RoutePickerButton()
                .frame(width: 24, height: 24)
                .help("AirPlay")
                .accessibilityLabel(Text("AirPlay"))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
    }
}

/// One of Music's speakers, as Control Center's Sound module lists them: choosing the row plays
/// there alone, the circle adds it to the rooms already playing, and each room playing has its
/// own volume under its name.
struct AirPlaySpeakerRow: View {
    let speaker: AirPlaySpeaker
    let model: MusicSpeakersModel
    @State private var isHovering = false
    @State private var volume: Double = 0
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Button {
                    model.chooseOnly(speaker)
                } label: {
                    HStack(spacing: 10) {
                        DeviceGlyph(symbol: symbol, isCurrent: speaker.isSelected)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        Text(speaker.name)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(speaker.isSelected ? .isSelected : [])
                .accessibilityHint(speaker.isSelected ? Text(verbatim: "") : Text("Plays the music here alone"))

                Button {
                    model.toggle(speaker)
                } label: {
                    Image(systemName: speaker.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(speaker.isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary), Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(speaker.isSelected ? "Stop Playing Here" : "Also Play Here")
                .accessibilityLabel(speaker.isSelected ? Text("Stop Playing on \(speaker.name)") : Text("Also Play on \(speaker.name)"))
            }
            if speaker.isSelected, speaker.volume != nil {
                Slider(value: $volume, in: 0...100) { editing in
                    isDragging = editing
                }
                .controlSize(.mini)
                .padding(.leading, 38)
                .padding(.trailing, 2)
                .accessibilityLabel(Text("\(speaker.name) Volume"))
                .onChange(of: volume) { _, new in
                    if isDragging || Int(new.rounded()) != speaker.volume {
                        model.setVolume(Int(new.rounded()), of: speaker)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onAppear { volume = Double(speaker.volume ?? 0) }
        // Volume changed from elsewhere, from the HomePod's top or another device, unless
        // it's being dragged here.
        .onChange(of: speaker.volume) { _, new in
            if !isDragging, let new { volume = Double(new) }
        }
    }

    private var symbol: String {
        speaker.kind == .computer ? NearbyDevices.thisDeviceSymbol : speaker.kind.symbol
    }
}
#endif

#if os(iOS)
/// Where this iPhone's sound is going, as the top of Control Center's AirPlay list says it,
/// and the system's own picker to send it somewhere else. The whole row opens the picker.
struct SpeakerRouteRow: View {
    let route: SpeakerRoute?

    var body: some View {
        HStack(spacing: 14) {
            DeviceGlyph(symbol: route?.symbol ?? NearbyDevices.thisDeviceSymbol, isCurrent: route != nil)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body)
                    .lineLimit(2)
                Text(kindName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "airplay.audio")
                .font(.title3)
                .foregroundStyle(route == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        // The system's picker, clear and over the whole row, takes the tap.
        .overlay {
            RoutePicker(isHidden: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("AirPlay"))
        .accessibilityValue(Text(name))
        .accessibilityAddTraits(.isButton)
    }

    private var name: String {
        guard let route else { return UIDevice.current.model }
        return route.names.formatted(.list(type: .and))
    }

    private var kindName: String {
        switch route?.kind {
        case nil: String(localized: "Speaker")
        case .airPlay: String(localized: "AirPlay")
        case .bluetooth: String(localized: "Bluetooth")
        case .car: String(localized: "CarPlay")
        case .wired: String(localized: "Headphones")
        case .screen: String(localized: "Display")
        }
    }
}
#endif

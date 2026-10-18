import SwiftUI
import TracksCore

/// Another device's song as Control Center's Now Playing: where it's playing over the song,
/// its cover's colours behind it, a scrubber, its controls, and the way to bring it here.
struct RemoteDeviceCard: View {
    let device: NearbyDevices.Device
    var close: (() -> Void)?
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isMoving = false
    @State private var notFound = false
    @State private var tint: Color?

    var body: some View {
        let state = device.state ?? NearbyState()
        let cover = CoverArt.url(state.artworkURL, seed: state.album ?? state.title ?? device.name)
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            // At the largest text sizes the song goes under its cover, with room to wrap.
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
            let lines = typeSize.isAccessibilitySize ? 3 : 1
            layout {
                CoverImage(cover: cover, size: Metrics.cover)
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Label {
                        Text(state.isPlaying ? "Playing on \(device.name)" : "Paused on \(device.name)")
                    } icon: {
                        Image(systemName: device.kind.symbol)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(lines)
                    .padding(.bottom, 2)
                    Text(state.title ?? "")
                        .font(.headline)
                        .lineLimit(lines)
                    Text(state.artist ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(lines)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            RemoteScrubber(device: device, state: state)
            RemoteTransport(device: device, state: state, size: .large)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                playHereButton
                #if os(macOS)
                if model.controlledDevice?.id != device.id {
                    Button {
                        model.control(device)
                        close?()
                    } label: {
                        Image(systemName: "rectangle.bottomhalf.inset.filled")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 32, height: 30)
                            .background(.white.opacity(0.18), in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.pressable)
                    .help("Show in the Player")
                    .accessibilityLabel("Show in the Player")
                }
                #endif
            }
        }
        .padding(Metrics.padding)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background {
            ZStack {
                tint ?? CoverStage.fallback
                CoverImage(cover: cover, size: 300, isBare: true)
                    .scaleEffect(2.2)
                    .blur(radius: 40)
                    .saturation(1.3)
                    .opacity(0.85)
                LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
        }
        .clipShape(.rect(cornerRadius: Metrics.radius, style: .continuous))
        .coverTint(of: cover, into: $tint)
        .animation(reduceMotion ? nil : .snappy, value: state.title)
        .sensoryFeedback(.success, trigger: isMoving) { was, now in was && !now && !notFound }
        .sensoryFeedback(.error, trigger: notFound) { _, now in now }
    }

    private var playHereButton: some View {
        Button {
            Task {
                isMoving = true
                let moved = await model.playHere(from: device)
                isMoving = false
                if moved {
                    close?()
                } else {
                    notFound = true
                    try? await Task.sleep(for: .seconds(3))
                    notFound = false
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isMoving {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Image(systemName: notFound ? "exclamationmark.circle" : NearbyDevices.thisDeviceSymbol)
                }
                Text(notFound ? "Not Available Here" : playHereTitle)
                    .contentTransition(.opacity)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .frame(minHeight: Metrics.buttonHeight)
            .frame(maxWidth: .infinity)
            .background(.white, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.pressable)
        .disabled(isMoving)
        .animation(.snappy(duration: 0.2), value: notFound)
    }

    private var playHereTitle: LocalizedStringKey {
        switch NearbyDevices.thisKind {
        case .iPhone: "Play on This iPhone"
        case .iPad: "Play on This iPad"
        default: "Play on This Mac"
        }
    }

    private enum Metrics {
        #if os(macOS)
        static let cover: CGFloat = 48
        static let spacing: CGFloat = 12
        static let padding: CGFloat = 14
        static let radius: CGFloat = 16
        static let buttonHeight: CGFloat = 30
        #else
        static let cover: CGFloat = 60
        static let spacing: CGFloat = 14
        static let padding: CGFloat = 16
        static let radius: CGFloat = 22
        static let buttonHeight: CGFloat = 40
        #endif
    }
}

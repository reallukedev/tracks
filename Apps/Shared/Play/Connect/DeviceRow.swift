import SwiftUI
import TracksCore

/// One of your devices in the list, as AirPlay lists speakers: its symbol, its name, what it's
/// doing, and a checkmark on the one with the music. Choosing one moves the music there.
struct DeviceRow: View {
    enum Trailing: Equatable {
        case none, current, working
    }

    let symbol: String
    let name: String
    let detail: String
    var isPlaying = false
    var trailing = Trailing.none
    /// Seen lately, not here now: dimmed, and nothing to choose.
    var isAway = false
    /// The detail says something went wrong.
    var isProblem = false
    /// Nothing to choose here now: dimmed, as a disabled control is.
    var isEnabled = true
    /// What choosing it does, for VoiceOver.
    var hint: Text?
    var action: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        if let action, !isAway {
            Button(action: action) { content.opacity(isEnabled ? 1 : 0.45) }
                .buttonStyle(.plain)
                .disabled(trailing == .working || !isEnabled)
                .accessibilityHint(trailing == .current ? Text(verbatim: "") : hint ?? Text(verbatim: ""))
                .accessibilityAddTraits(trailing == .current ? .isSelected : [])
                #if os(macOS)
                .onHover { isHovering = $0 && isEnabled }
                .background(isHovering && trailing != .current ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
                #endif
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // The words get the whole width, under the symbol and the checkmark.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        glyph
                        Spacer(minLength: 8)
                        mark
                    }
                    words
                }
            } else {
                HStack(spacing: Metrics.gap) {
                    glyph
                    words
                    Spacer(minLength: 8)
                    mark
                }
            }
        }
        .padding(.vertical, Metrics.verticalPadding)
        #if os(macOS)
        .padding(.horizontal, 6)
        #endif
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var glyph: some View {
        DeviceGlyph(symbol: symbol, isCurrent: trailing == .current, isAway: isAway)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(Metrics.nameFont)
                .foregroundStyle(isAway ? .secondary : .primary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            HStack(spacing: 4) {
                if isPlaying {
                    PlayingWaveform(isActive: true, color: Metrics.tintsPlaying ? .accentColor : .secondary)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                Text(detail)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .contentTransition(.opacity)
            }
            .font(Metrics.detailFont)
            .foregroundStyle(isProblem ? AnyShapeStyle(.red) : isPlaying && Metrics.tintsPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }

    private var mark: some View {
        Group {
            switch trailing {
            case .current:
                Image(systemName: "checkmark.circle.fill")
                    .font(Metrics.checkFont)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .working:
                ProgressView()
                    .controlSize(.small)
            case .none:
                EmptyView()
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityHidden(true)
    }

    private enum Metrics {
        #if os(macOS)
        static let gap: CGFloat = 10
        static let nameFont = Font.callout
        static let detailFont = Font.caption
        static let checkFont = Font.title3
        static let verticalPadding: CGFloat = 5
        /// Accent text washes out on a popover's vibrant material, so the circle and the
        /// checkmark say it alone.
        static let tintsPlaying = false
        #else
        static let gap: CGFloat = 14
        static let nameFont = Font.body
        static let detailFont = Font.subheadline
        static let checkFont = Font.title3
        static let verticalPadding: CGFloat = 2
        static let tintsPlaying = true
        #endif
    }
}

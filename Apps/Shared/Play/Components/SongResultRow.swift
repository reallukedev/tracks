import SwiftUI

/// A song among search results, around its ``TrackRow``.
///
/// On iPhone a tap plays it. On the Mac it answers as Music's results do: it highlights under
/// the pointer with Play over its cover, a click selects it, a double-click or Return plays,
/// and the arrow keys move the selection. The selection is the keyboard focus, so it's one
/// row at a time and goes when you click elsewhere.
struct SongResultRow<Label: View>: View {
    let id: String
    let selection: FocusState<String?>.Binding
    /// Moves the selection by a number of rows, for the arrow keys.
    var step: ((_ by: Int) -> Void)?
    let play: () -> Void
    @ViewBuilder var label: Label

    #if os(macOS)
    @State private var isHovered = false
    #endif

    var body: some View {
        #if os(macOS)
        let isSelected = selection.wrappedValue == id
        label
            .overlay(alignment: .leading) {
                if isHovered {
                    Button(action: play) {
                        Image(systemName: "play.fill")
                            .font(.callout.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: TrackRow.cover, height: TrackRow.cover)
                            .background(.black.opacity(0.4), in: .rect(cornerRadius: CoverImage.radius(for: TrackRow.cover), style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Play")
                    .accessibilityHidden(true)
                    .transition(.opacity)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.primary.opacity(0.13)) : AnyShapeStyle(.quaternary.opacity(isHovered ? 0.6 : 0)))
                    .padding(.horizontal, -6)
            }
            .contentShape(.rect)
            .onHover { hovering in
                withAnimation(PlayMotion.hover) { isHovered = hovering }
            }
            .focusable()
            .focused(selection, equals: id)
            .focusEffectDisabled()
            .onTapGesture { selection.wrappedValue = id }
            .simultaneousGesture(TapGesture(count: 2).onEnded { play() })
            .onKeyPress(.return) { play(); return .handled }
            .onKeyPress(.upArrow) { step?(-1); return step == nil ? .ignored : .handled }
            .onKeyPress(.downArrow) { step?(1); return step == nil ? .ignored : .handled }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { play() }
        #else
        Button(action: play) {
            label
        }
        .buttonStyle(.plain)
        #endif
    }
}

extension View {
    /// Drags this out as songs, an album's link and the like, on the Mac, where anything that
    /// obviously goes somewhere can be dragged there. iPhone keeps its long press for the menu.
    func macDraggable<Payload: Transferable>(_ payload: @autoclosure @escaping () -> Payload, if isDraggable: Bool = true) -> some View {
        modifier(MacDrag(payload: payload, isDraggable: isDraggable))
    }

    /// The same, for something that may have nothing to drag, such as a link it may not have.
    func macDraggable<Payload: Transferable>(_ payload: Payload?) -> some View {
        modifier(OptionalMacDrag(payload: payload))
    }
}

private struct OptionalMacDrag<Payload: Transferable>: ViewModifier {
    let payload: Payload?

    func body(content: Content) -> some View {
        #if os(macOS)
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct MacDrag<Payload: Transferable>: ViewModifier {
    let payload: () -> Payload
    let isDraggable: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        if isDraggable {
            content.draggable(payload())
        } else {
            content
        }
        #else
        content
        #endif
    }
}

import SwiftUI

/// Buttons for a field of a cover's colour: the main action a white capsule with the field's
/// colour for its label, the rest a veil of white with white labels, as Music's are over a
/// cover. Keep system buttons everywhere else.
struct StageButtonStyle: ButtonStyle {
    enum Role { case primary, secondary }

    let role: Role
    /// The field's colour, for the primary's label. Nil draws it in near black.
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(role == .primary ? AnyShapeStyle(tint ?? Color(white: 0.1)) : AnyShapeStyle(.white))
            .padding(.horizontal, Self.horizontalPadding)
            .frame(minHeight: Self.height)
            .background(role == .primary ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.2)), in: .capsule)
            .contentShape(.capsule)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(PlayMotion.press, value: configuration.isPressed)
    }

    private var font: Font {
        #if os(macOS)
        .body.weight(.semibold)
        #else
        .headline
        #endif
    }

    #if os(macOS)
    static let height: CGFloat = 34
    static let horizontalPadding: CGFloat = 18
    #else
    static let height: CGFloat = 50
    static let horizontalPadding: CGFloat = 20
    #endif
}

extension ButtonStyle where Self == StageButtonStyle {
    /// The main action on a cover's field.
    static func stagePrimary(tint: Color?) -> StageButtonStyle { StageButtonStyle(role: .primary, tint: tint) }
    /// A second action on a cover's field.
    static var stageSecondary: StageButtonStyle { StageButtonStyle(role: .secondary) }
}

import SwiftUI

/// A field of a cover's own colour, deep enough that white type on it always reads (see
/// ``CoverTint``), for Now Playing and the headers of albums, playlists and mixes.
///
/// Read the colour with ``SwiftUI/View/coverTint(of:into:)``, and hand it to this and to the
/// primary button on it, so both wear the same colour.
struct CoverStage: View {
    let tint: Color?
    /// Behind a page's header the field stays even, and the page below meets it; behind the
    /// player it deepens toward the foot, under the controls.
    var deepens = true

    static let fallback = Color(white: 0.14)

    var body: some View {
        let base = tint ?? Self.fallback
        LinearGradient(
            colors: [base, base.mix(with: .black, by: deepens ? 0.45 : 0.18)],
            startPoint: .top,
            endPoint: .bottom
        )
        .animation(PlayMotion.tint, value: tint)
    }
}

extension View {
    /// Keeps `tint` at the colour of `cover`, following it as it changes. The last colour
    /// stays while the next is read, so a field never flashes grey between songs.
    func coverTint(of cover: CoverArt?, into tint: Binding<Color?>) -> some View {
        task(id: cover) {
            guard let cover, let found = await CoverTint.color(for: cover), !Task.isCancelled else { return }
            tint.wrappedValue = found
        }
    }
}

extension Color {
    /// A cover's glow, kept where the page's own text still reads on it: a bright cover's
    /// colour is deepened in Dark Mode, where the type over it is white, so a yellow or
    /// near-white cover gives a warm wash rather than a glare.
    func glowAdapted(to scheme: ColorScheme, in environment: EnvironmentValues) -> Color {
        let resolved = resolve(in: environment)
        let luminance = 0.2126 * Double(resolved.red) + 0.7152 * Double(resolved.green) + 0.0722 * Double(resolved.blue)
        switch scheme {
        case .dark where luminance > 0.4:
            return mix(with: .black, by: min(0.55, (luminance - 0.4) * 1.3))
        case .light where luminance > 0.85:
            // Near white on a white window disappears: a little depth so it's there at all.
            return mix(with: .gray, by: 0.25)
        default:
            return self
        }
    }
}

/// The cover's colour behind a page's header, strongest at the top and gone before the
/// content, adapted so the header's words read on it whatever the cover.
struct CoverGlow: View {
    let color: Color?
    /// How far past the top it reaches, under the toolbar.
    var overscroll: CGFloat = 120
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.self) private var environment

    var body: some View {
        let tint = color.map { $0.glowAdapted(to: colorScheme, in: environment) } ?? .clear
        LinearGradient(
            stops: [
                .init(color: tint.opacity(colorScheme == .dark ? 0.5 : 0.34), location: 0),
                .init(color: tint.opacity(colorScheme == .dark ? 0.2 : 0.12), location: 0.6),
                .init(color: tint.opacity(0), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .padding(.top, -overscroll)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(PlayMotion.tint, value: color)
    }
}

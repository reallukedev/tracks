import SwiftUI

/// The few places where the iPhone and the Mac name the same idea differently. Views say what
/// they mean ("a card's fill", "search under the title") and each platform answers in its own
/// idiom, rather than every view carrying its own `#if`.
extension Color {
    /// Behind a card or a well on the page: the grouped cell on iPhone, the quaternary fill on
    /// the Mac, where cards sit on the window's own background.
    static var cardFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemBackground)
        #else
        Color(nsColor: .quaternarySystemFill)
        #endif
    }

    /// The page itself.
    static var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A placeholder's fill while something loads: a little stronger than a card.
    static var placeholderFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemFill)
        #else
        Color(nsColor: .tertiarySystemFill)
        #endif
    }
}

extension SearchFieldPlacement {
    /// A page's own search: under the large title on iPhone, as Music's library searches are,
    /// and the window's toolbar on the Mac.
    static func pageSearch(alwaysShown: Bool = true) -> SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: alwaysShown ? .always : .automatic)
        #else
        .toolbar
        #endif
    }
}

/// Where Tracks’ access to Apple Music is switched on.
enum SystemSettingsLink {
    /// Settings › Tracks on iPhone; Privacy & Security › Media & Apple Music on the Mac.
    static var musicAccess: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")
        #endif
    }
}

extension View {
    /// A field for an address, a user name or a password: no capitals, no corrections, and
    /// the URL keyboard on iPhone when it's an address.
    func literalEntry(isAddress: Bool = false) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(isAddress ? .URL : .default)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// A field for a name, capitalised as a title is.
    func titleEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    /// A field for a whole number.
    func numberEntry() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
}

extension View {
    /// An icon-only menu inside a page: on the Mac, a borderless button with no pop-up
    /// chevron, as the "…" beside an item is in Music. The iPhone's menus look right as they are.
    func iconMenuStyle() -> some View {
        #if os(macOS)
        menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        #else
        self
        #endif
    }
}

#if os(macOS)
extension View {
    /// A page whose colour runs up under the Mac's title bar: the colour meets the top edge
    /// clean, and the bar's material comes back once the page scrolls under it. The title is
    /// empty rather than removed, as a window without one drops the material altogether.
    func headerUnderBar() -> some View {
        modifier(HeaderUnderBar())
    }
}

private struct HeaderUnderBar: ViewModifier {
    @State private var isScrolled = false

    func body(content: Content) -> some View {
        content
            .navigationTitle("")
            .toolbarBackgroundVisibility(isScrolled ? .automatic : .hidden, for: .windowToolbar)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 8
            } action: { _, scrolled in
                isScrolled = scrolled
            }
    }
}
#endif

extension View {
    /// What every page of the Mac's main window wears around it: the player's bar at its foot.
    /// Applied by the page, not the window, since a pushed page takes the stack's place. The
    /// iPhone's player lives on its tab bar instead.
    func pageChrome() -> some View {
        #if os(macOS)
        ColumnLayout { nowPlayingBar() }
        #else
        self
        #endif
    }
}

extension View {
    /// A chart's axis labels grow with Dynamic Type only so far, as Health's do: past that they
    /// crowd out the bars they label. The words around the chart still grow.
    func chartTextSize() -> some View {
        dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

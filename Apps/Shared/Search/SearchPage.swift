import SwiftUI
import TracksCore

/// Search, as a page of its own: the Mac sidebar's first row and the iPhone's Search tab.
/// Before you type, what you searched lately and things to browse; then results from the
/// scope chosen above them: Apple Music, your library, or your history.
struct SearchPage: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFieldFocused: Bool
    /// Whether the page is the one showing: a hidden tab can't take the cursor.
    @State private var isShowing = false

    var body: some View {
        @Bindable var session = model.search
        let source = model.musicSource
        results
            .navigationTitle("Search")
            .searchable(text: $session.query, placement: Self.fieldPlacement, prompt: session.scope.prompt(for: source))
            // Return keeps the search, as acting on a result does.
            .onSubmit(of: .search) { session.remember(source: source) }
            .searchFocused($isFieldFocused)
            #if os(macOS)
            // Where the title would be: the scope says what the page is.
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) { scopePicker }
                ToolbarItem(placement: .primaryAction) {
                    identifyButton
                        .popover(isPresented: $session.isIdentifying, arrowEdge: .bottom) {
                            IdentifySongView()
                                .padding(20)
                                .frame(width: 320)
                        }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { identifyButton }
            }
            .safeAreaBar(edge: .top) {
                scopePicker
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PlayMetrics.margin)
                    .padding(.bottom, 8)
            }
            .sheet(isPresented: $session.isIdentifying) {
                NavigationStack {
                    ScrollView {
                        IdentifySongView()
                            .padding(.horizontal, PlayMetrics.margin)
                            .padding(.bottom, 24)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark", role: .close) { session.isIdentifying = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            #endif
            .onAppear {
                isShowing = true
                session.keepScope(for: source)
                takeFocusIfAsked()
            }
            .onDisappear { isShowing = false }
            .onChange(of: source) { session.keepScope(for: source) }
            .onChange(of: session.wantsFocus) { takeFocusIfAsked() }
    }

    /// Puts the cursor in the field when something asked for it, once the page is showing.
    /// The request waits while it isn't, for the tab or the page to come forward.
    private func takeFocusIfAsked() {
        guard model.search.wantsFocus, isShowing else { return }
        Task {
            // After the page has settled in the window, or the field isn't there to focus.
            try? await Task.sleep(for: .milliseconds(150))
            isFieldFocused = true
            model.search.wantsFocus = false
        }
    }

    @ViewBuilder
    private var results: some View {
        let session = model.search
        let search: (String) -> Void = { session.query = $0 }
        switch session.scope {
        case .history:
            HistorySearchResults(query: session.query, search: search)
        case .library where model.musicSource == .yourMusic:
            YourMusicSearchResults(query: session.query, search: search)
        case .library:
            #if os(macOS)
            LibrarySearchResults(query: session.query)
            #else
            MusicSearchResults(query: session.query, scope: .library, search: search)
            #endif
        case .appleMusic:
            MusicSearchResults(query: session.query, scope: .appleMusic, search: search)
        }
    }

    /// Names the song playing nearby, as Control Center's Music Recognition does.
    private var identifyButton: some View {
        Button("Identify Song", systemImage: "shazam.logo") { model.search.isIdentifying = true }
            .help("Identify the song playing near you")
    }

    private var scopePicker: some View {
        @Bindable var session = model.search
        let source = model.musicSource
        return Picker("Search In", selection: $session.scope) {
            ForEach(SearchScope.scopes(for: source)) { scope in
                Text(scope.title(for: source)).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        #if os(macOS)
        .fixedSize()
        #endif
    }

    /// The toolbar's field on the Mac, as Finder and Mail have it; under the large title on
    /// iPhone, always showing, as on a page that's for nothing but searching.
    #if os(macOS)
    private static let fieldPlacement = SearchFieldPlacement.toolbar
    #else
    private static let fieldPlacement = SearchFieldPlacement.navigationBarDrawer(displayMode: .always)
    #endif
}

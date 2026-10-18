import SwiftUI
import TracksCore

extension View {
    /// Get Info on iPhone: a sheet that opens at half height with the song and your history
    /// with it, and pulls up for the rest.
    ///
    /// - Parameters:
    ///   - isActive: false while something presented over this view shows the sheet itself, as
    ///     Now Playing does over the tabs.
    ///   - go: where Go to Album and the like lead, once the sheet has closed.
    func songInfoSheet(_ model: AppModel, isActive: Bool = true, go: @escaping (PlayRoute) -> Void) -> some View {
        modifier(SongInfoSheet(model: model, isActive: isActive, go: go))
    }
}

private struct SongInfoSheet: ViewModifier {
    let model: AppModel
    let isActive: Bool
    let go: (PlayRoute) -> Void

    func body(content: Content) -> some View {
        let presenter = model.songInfo
        content
            .sheet(isPresented: Binding(
                get: { isActive && presenter.subject != nil },
                set: { if !$0 { presenter.subject = nil } }
            )) {
                SongInfoView(presenter: presenter) { presenter.subject = nil }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .environment(\.openPlayRoute, OpenPlayRouteAction(stack: "songInfo") { route in
                        presenter.subject = nil
                        go(route)
                    })
            }
    }
}

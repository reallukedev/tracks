import SwiftUI
import MusicKit
import TracksCore

/// Get Info: a song's page of its own, in the Mac's Song Info window and the iPhone's sheet.
/// A sample or a similar song opens over it, with Back to return.
struct SongInfoView: View {
    let presenter: SongInfoPresenter
    /// The sheet's close button. The Mac's window has its own.
    var onClose: (() -> Void)?
    @State private var path: [SongInfoSubject] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let subject = presenter.subject ?? presenter.lastShown {
                    SongInfoPage(subject: subject)
                        // A fresh page per song, so one song's answers never show under another's name.
                        .id(subject.identity)
                } else {
                    ContentUnavailableView("No Song", systemImage: "music.note", description: Text("Choose Get Info on a song to see it here."))
                }
            }
            .closeButton(onClose)
            .navigationDestination(for: SongInfoSubject.self) { subject in
                SongInfoPage(subject: subject)
                    .closeButton(onClose)
            }
        }
        // Another song asked for from outside starts again from it.
        .onChange(of: presenter.request) { path = [] }
    }
}

private extension View {
    @ViewBuilder
    func closeButton(_ onClose: (() -> Void)?) -> some View {
        #if os(iOS)
        if let onClose {
            toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close, action: onClose)
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// One song's info: who it's by and what to do with it, your history with it, and what Apple
/// Music, MusicBrainz and Last.fm know. Two columns on a wide Mac window.
struct SongInfoPage: View {
    let subject: SongInfoSubject
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var info: SongInfoModel
    @State private var retries = 0
    @State private var isWide = false
    @State private var showsTitle = false

    init(subject: SongInfoSubject) {
        self.subject = subject
        let info = SongInfoModel()
        info.reset(for: subject)
        _info = State(initialValue: info)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                SongInfoHeader(subject: subject, info: info)
                if isWide {
                    HStack(alignment: .top, spacing: Metrics.sectionSpacing) {
                        // Each column its own height: cards fill what they're offered, and the
                        // shorter column would otherwise stretch its cards to the taller one.
                        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                            historySections
                            musicSections
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                            aboutSections
                            lastFMSections
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    historySections
                    aboutSections
                    musicSections
                    lastFMSections
                }
            }
            .padding(Self.pagePadding)
            .frame(maxWidth: isWide ? 1_100 : 680)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: info.sectionsShown)
        }
        .groupedBackground()
        #if os(macOS)
        // The window's width only decides the columns; nothing here sizes the window.
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { isWide = $0 }
        #endif
        #if os(iOS)
        // The header names the song; the bar takes over once it scrolls away.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > Self.titleThreshold
        } action: { _, isPast in
            showsTitle = isPast
        }
        .navigationTitle(showsTitle ? subject.title : "")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle(subject.title)
        #endif
        .task(id: model.library.revision) {
            await info.loadHistory(of: subject, library: model.library)
        }
        .task(id: retries) {
            await info.loadDetails(of: subject, model: model)
        }
    }

    private var history: SongInfoHistory? { info.history.value }

    @ViewBuilder
    private var historySections: some View {
        SongInfoHistorySection(part: info.history)
    }

    /// What the song is: its facts, what it borrows, who made it, and its other recordings.
    @ViewBuilder
    private var aboutSections: some View {
        SongInfoDetailsSection(
            subject: subject,
            about: info.about,
            metadata: history?.profile?.metadata,
            credits: info.credits.value,
            versions: info.versions.value
        )
        SongInfoSamplesSection(credits: info.credits.value)
        SongInfoCreditsSection(part: info.credits)
        SongInfoVersionsSection(subject: subject, versions: info.versions.value)
    }

    /// The songs around it: its album, and its artist's best known.
    @ViewBuilder
    private var musicSections: some View {
        SongInfoAlbumSection(subject: subject, related: info.related.value, history: history)
        SongInfoArtistSection(subject: subject, related: info.related.value, history: history)
    }

    @ViewBuilder
    private var lastFMSections: some View {
        SongInfoLastFMSection(subject: subject, part: info.lastFM)
        SongInfoFootnote(info: info) {
            info.retry()
            retries += 1
        }
    }

    /// About where the header's title passes under the bar.
    private static let titleThreshold: CGFloat = 60

    #if os(macOS)
    private static let pagePadding: CGFloat = 20
    #else
    private static let pagePadding: CGFloat = 16
    #endif
}

private extension SongInfoModel {
    /// Which sections are on the page, so one arriving or leaving moves the rest smoothly
    /// rather than jumping.
    var sectionsShown: [Bool] {
        [
            history.isLoading, about.isLoading, related.value != nil,
            credits.value?.sections.isEmpty == false, credits.value?.hasSamples == true,
            versions.value != nil, lastFM.value != nil, isOffline,
        ]
    }
}

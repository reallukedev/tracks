#if DEBUG
import SwiftUI

/// `-TracksBackdropLab living` (or any background's stored name), in a Debug build: that
/// background for many covers at once, each under a cover and a song's name in white, to judge
/// the colours and whether the words read. The covers are `-TracksDemoCovers`, then a stand-in
/// cover, then a song with none.
struct BackdropLab: View {
    let style: NowPlayingBackground

    static var requested: NowPlayingBackground? {
        UserDefaults.standard.string(forKey: "TracksBackdropLab").flatMap(NowPlayingBackground.init)
    }

    private var covers: [CoverArt] {
        let urls = UserDefaults.standard.string(forKey: "TracksDemoCovers")?.split(separator: "|").map(String.init) ?? []
        return urls.map { .url($0, seed: $0) } + [.url(nil, seed: NowPlayingBackdropPicker.sample), .url(nil, seed: "Northbound")]
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = proxy.size.width > proxy.size.height ? 3 : 2
            let rows = (covers.count + columns - 1) / columns
            let height = proxy.size.height / CGFloat(rows)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                ForEach(covers, id: \.self) { cover in
                    tile(cover)
                        .frame(height: height - 2)
                }
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
    }

    private func tile(_ cover: CoverArt) -> some View {
        HStack(spacing: 18) {
            CoverImage(cover: cover, size: 92)
                .backdropFocus()
            VStack(alignment: .leading, spacing: 2) {
                Text("Song Title Here").font(.title3.bold())
                Text("Artist Name").foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nowPlayingBackdrop(cover: cover, tint: nil, isPlaying: true, style: style)
        .clipped()
    }
}
#endif

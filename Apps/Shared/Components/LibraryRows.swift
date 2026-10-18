import SwiftUI
import TracksCore

struct ArtistRow: View {
    let artist: ArtistTally

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: artist.artworkURL, seed: artist.name, size: 44, isCircle: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name).lineLimit(1)
                Text("^[\(artist.count) play](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AlbumRow: View {
    let album: AlbumTally

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: album.artworkURL, seed: album.title, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).lineLimit(1)
                Text(album.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

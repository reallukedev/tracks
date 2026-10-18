#if DEBUG
import Foundation
import TracksCore

/// Pretend sessions for screenshots, since a simulator can't join a real one without a host.
/// `-TracksClipDemo` names the scene: `joined`, `joining`, `reconnecting`, `ended`, `nocode`.
@MainActor
enum ClipDemo {
    static var isOn: Bool { UserDefaults.standard.string(forKey: "TracksClipDemo") != nil }

    private static let songs: [SharePlaySong] = [
        SharePlaySong(catalogID: "1", title: "Espresso", artistName: "Sabrina Carpenter", albumTitle: "Short n' Sweet"),
        SharePlaySong(catalogID: "2", title: "Good Luck, Babe!", artistName: "Chappell Roan"),
        SharePlaySong(catalogID: "3", title: "Birds of a Feather", artistName: "Billie Eilish", albumTitle: "Hit Me Hard and Soft"),
        SharePlaySong(catalogID: "4", title: "Please Please Please", artistName: "Sabrina Carpenter", albumTitle: "Short n' Sweet"),
        SharePlaySong(catalogID: "5", title: "Taste", artistName: "Sabrina Carpenter", albumTitle: "Short n' Sweet", isExplicit: true),
        SharePlaySong(catalogID: "6", title: "Pink Pony Club", artistName: "Chappell Roan", albumTitle: "The Rise and Fall of a Midwest Princess"),
        SharePlaySong(catalogID: "7", title: "Apple", artistName: "Charli xcx", albumTitle: "Brat"),
    ]

    static func start(_ scene: String, in model: ClipModel) {
        guard scene != "nocode" else {
            model.open(URL(string: "https://appclip.apple.com/id?p=com.luke.tracks.Clip"))
            return
        }
        model.open(SharePlayInvite().url)
        guard let session = model.session else { return }
        session.stop()
        let snapshot = SharePlaySnapshot(
            nowPlaying: SharePlayTrack(id: "now", title: "Orange Sky", artistName: "Juniper Lane"),
            isPlaying: true,
            upNext: songs.prefix(4).enumerated().map { index, song in
                SharePlayTrack(id: "q\(index)", title: song.title, artistName: song.artistName, isFromSharePlay: index == 1)
            },
            upNextCount: 12
        )
        session.pretend({ guest in
            if scene != "joining" { guest.receive(snapshot) }
            if scene == "ended" { guest.end() }
        }, isSlow: scene == "joining", isReconnecting: scene == "reconnecting")
        if let search = UserDefaults.standard.string(forKey: "TracksClipSearch") { model.query = search }
    }

    static func search(_ term: String) -> [SharePlaySong] {
        let folded = term.lowercased()
        return songs.filter { "\($0.title) \($0.artistName)".lowercased().contains(folded) }
    }

    static func add(_ song: SharePlaySong, placement: SharePlayPlacement, in session: SharePlayCodeGuest) {
        var request: SharePlayAddRequest?
        session.pretend({ request = $0.add(song, placement: placement, at: .now) })
        guard let request else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            session.pretend({ $0.receive(SharePlayAddReply(requestID: request.id, outcome: .added(placement))) })
        }
    }
}
#endif

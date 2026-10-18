import Testing
import Foundation
@testable import TracksCore

/// What a fresh install does before anyone opens Settings.
///
/// These are the promises the copy in Settings and the README make, and several of them are
/// load-bearing: capture on by default is the whole app, and the playlist cap is what keeps
/// "Heard on Radio" from growing without end. Changing one should mean changing this.
@Suite("Settings defaults")
struct CaptureSettingsDefaultsTests {
    /// A fresh, empty suite per test, removed when the test finishes.
    private let scratch = ScratchDefaults()
    private var settings: CaptureSettings { scratch.settings }

    // MARK: - What gets kept

    @Test("on-demand plays are kept, so history isn't only radio")
    func keepsOnDemand() {
        #expect(settings.capturesOnDemand)
    }

    @Test("listening from while Tracks was closed is recovered")
    func recoversRecentlyPlayed() {
        #expect(settings.importsRecentlyPlayed)
    }

    @Test("a song counts once half of it has played, as Last.fm counts a scrobble")
    func minimumListen() {
        #expect(settings.minimumListenShare == 0.5)
    }

    @Test("the same song again inside ten minutes counts once")
    func dedupeWindow() {
        #expect(settings.dedupePolicy.window == 10 * 60)
    }

    /// It captures songs a station never played, so it stays an escape hatch.
    @Test("nothing is forced to count as radio")
    func doesNotForceCapture() {
        #expect(!settings.forceCapture)
    }

    // MARK: - The playlist

    @Test("radio songs are added to Heard on Radio")
    func playlistDefaults() {
        #expect(settings.autoAddToPlaylist)
        #expect(settings.playlistName == "Heard on Radio")
        #expect(settings.playlistID == nil)
    }

    // MARK: - Scrobbling

    @Test("scrobbling is on, though nothing is sent until an account is connected")
    func scrobblesByDefault() {
        #expect(settings.scrobblesToLastFM)
    }

    /// On the iPhone, recovered songs are most of the history; leaving them out meant most
    /// listening never reached Last.fm.
    @Test("recovered songs are scrobbled too")
    func scrobblesRecoveredSongs() {
        #expect(settings.scrobblesImported)
    }

    // MARK: - Playing back

    /// It starts music on its own and plays audibly, so it has to be asked for.
    @Test("play back does not start on its own")
    func autoPlayBackIsOff() {
        #expect(!settings.autoPlayBack)
    }

    // MARK: - Appearance

    @Test("the menu bar shows the note symbol and cross-fades between songs")
    func menuBarDefaults() {
        #expect(settings.menuBarLabelStyle == .note)
        #expect(settings.menuBarLabelFormat == MenuBarLabelFormat.default)
        #expect(settings.animatesMenuBar)
        #expect(settings.showsMenuBarProgress)
    }

    @Test("the Today widget lists what play back will play next")
    func widgetDefaults() {
        #expect(settings.showsUpNextInWidget)
    }

    // MARK: - Nothing excluded yet

    @Test("no stations are excluded and no songs forgotten")
    func nothingExcluded() {
        #expect(settings.excludedStations.isEmpty)
        #expect(settings.forgottenSongs.isEmpty)
        #expect(settings.recentlyPlayedAnchor.isEmpty)
    }
}

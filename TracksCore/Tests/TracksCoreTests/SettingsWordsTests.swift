import Testing
import Foundation
@testable import TracksCore

/// The words Settings shows. The root row, the page's status line and the Mac pane all read
/// these, so a state nobody rendered still says the right thing.
@Suite("Settings words")
struct SettingsWordsTests {

    // MARK: - History

    @Test("the History row says whether on-demand songs are kept")
    func historyShort() {
        #expect(HistorySettingsWords.short(keepsOnDemand: true) == "All Music")
        #expect(HistorySettingsWords.short(keepsOnDemand: false) == "Radio Only")
    }

    @Test("History's status says what's kept, then when a play counts")
    func historyStatus() {
        #expect(HistorySettingsWords.status(keepsOnDemand: true, minimumListenShare: 0.5)
            == "Keeping everything you play · counts after 50% of a song")
        #expect(HistorySettingsWords.status(keepsOnDemand: false, minimumListenShare: 0)
            == "Keeping radio only · counts as soon as a song starts")
    }

    @Test("Counts After reads Straight Away at zero, and its footer follows the slider")
    func countsAfter() {
        #expect(HistorySettingsWords.countsAfterValue(0) == "Straight Away")
        #expect(HistorySettingsWords.countsAfterValue(0.25) == "25%")
        #expect(HistorySettingsWords.countsAfterFooter(0).hasPrefix("Every song is kept as soon as it starts"))
        #expect(HistorySettingsWords.countsAfterFooter(0.5) == "A song is kept once 50% of it has played, so skipping through doesn’t fill your history. For a song 4 minutes long, that’s 2 minutes.")
    }

    /// Steps of 0.05 don't add up exactly, so the slider can hand over 0.15000000000000002.
    @Test("a slider step a hair off a whole percent still reads as one")
    func percentRounds() {
        #expect(HistorySettingsWords.countsAfterValue(0.05 * 3) == "15%")
    }

    @Test("the same-song window reads in minutes, singular at one")
    func sameSongWindow() {
        #expect(HistorySettingsWords.windowValue(minutes: 10) == "10 min")
        #expect(HistorySettingsWords.windowFooter(minutes: 1) == "Hearing the same song again within 1 minute counts once.")
        #expect(HistorySettingsWords.windowFooter(minutes: 10) == "Hearing the same song again within 10 minutes counts once.")
    }

    // MARK: - Radio

    @Test("Radio's status names the playlist songs go into")
    func radioStatus() {
        let adding = RadioSettingsWords.Playlist(addsSongs: true, name: "Heard on Radio")

        #expect(RadioSettingsWords.status(adding) == "Adding radio songs to “Heard on Radio”")
        #expect(RadioSettingsWords.short(adding) == "Heard on Radio")
    }

    @Test("with adding off, the row shows no playlist")
    func radioOff() {
        let off = RadioSettingsWords.Playlist(addsSongs: false, name: "Heard on Radio")

        #expect(RadioSettingsWords.short(off) == nil)
        #expect(RadioSettingsWords.status(off).hasPrefix("Radio songs are kept in your history."))
    }

    @Test("a blank name reads as the default playlist, as capture reads it")
    func blankPlaylistName() {
        let blank = RadioSettingsWords.Playlist(addsSongs: true, name: "   ")

        #expect(blank.name == CaptureSettings.defaultPlaylistName)
    }

    // MARK: - Last.fm

    @Test("Last.fm's row and line follow the connection", arguments: [
        (LastFMSettingsStatus.notSetUp, "Not Set Up", SettingsTone.plain),
        (.connecting, "Connecting…", .plain),
        (.connected(username: "rj", scrobbles: true), "rj", .plain),
        (.connected(username: "rj", scrobbles: false), "Off", .plain),
        (.failed("Last.fm is down."), "Not Set Up", .failure),
    ])
    func lastFM(status: LastFMSettingsStatus, short: String, tone: SettingsTone) {
        #expect(status.short == short)
        #expect(status.tone == tone)
    }

    @Test("a connected account says who is scrobbling")
    func lastFMLine() {
        #expect(LastFMSettingsStatus.connected(username: "rj", scrobbles: true).line == "Scrobbling as rj")
        #expect(LastFMSettingsStatus.connected(username: "rj", scrobbles: false).line == "Connected as rj · scrobbling is off")
        #expect(LastFMSettingsStatus.failed("Last.fm is down.").line == "Last.fm is down.")
    }

    // MARK: - Apple Music

    @Test("Apple Music access asks for attention only when it's blocked", arguments: [
        (MusicAccessStatus.allowed, "Allowed", SettingsTone.plain),
        (.notAsked, "Not Set Up", .plain),
        (.denied, "Off", .attention),
        (.restricted, "Restricted", .attention),
    ])
    func musicAccess(status: MusicAccessStatus, short: String, tone: SettingsTone) {
        #expect(status.short == short)
        #expect(status.tone == tone)
        #expect(!status.line.isEmpty)
    }

    // MARK: - iCloud

    private func cloud(
        configured: Bool = true,
        wants: Bool = true,
        running: Bool = true,
        startFailure: String? = nil,
        account: CloudSyncStatus.Account? = .available,
        accountError: String? = nil,
        failure: CloudSyncMonitor.Failure? = nil,
        lastSynced: Date? = nil
    ) -> CloudSyncStatus {
        CloudSyncStatus.resolve(
            isConfigured: configured,
            wantsSync: wants,
            isRunning: running,
            startFailure: startFailure,
            account: account,
            accountError: accountError,
            failure: failure,
            lastSynced: lastSynced
        )
    }

    /// Turning sync on showed "The iCloud container could not be opened." in red, because the
    /// store that was open had been opened without sync. It starts next launch; say that.
    @Test("a switch flipped this session takes effect next launch")
    func switchTakesEffectNextLaunch() {
        #expect(cloud(wants: true, running: false) == .startsNextLaunch)
        #expect(cloud(wants: false, running: true) == .stopsNextLaunch)
        #expect(cloud(wants: false, running: false) == .off)
        #expect(cloud(wants: true, running: false, startFailure: "Refused") == .couldNotStart("Refused"))
    }

    @Test("the account is checked before what the mirror reported")
    func accountComesFirst() {
        let failure = CloudSyncMonitor.Failure(activity: .export, message: "Refused", date: .now)

        #expect(cloud(account: .noAccount, failure: failure) == .notSignedIn)
        #expect(cloud(account: nil) == .checking)
        #expect(cloud(accountError: "Offline") == .accountError("Offline"))
        #expect(cloud(failure: failure) == .failed(.export, "Refused"))
        #expect(cloud(configured: false, wants: false) == .unavailable)
    }

    @Test("an export failure is said plainly, with iCloud's reason kept for underneath")
    func failureWords() {
        let status = CloudSyncStatus.failed(.export, "Refused")

        #expect(status.line() == "iCloud isn’t accepting this device’s history, so your other devices won’t see it.")
        #expect(status.reason == "Refused")
        #expect(status.short == "Not Syncing")
        #expect(status.tone == .failure)
    }

    @Test("on says when it last synced")
    func onWords() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(CloudSyncStatus.on(lastSynced: now.addingTimeInterval(-10)).line(now: now) == "On · synced just now")
        #expect(CloudSyncStatus.on(lastSynced: nil).line(now: now) == "On · your history syncs to all your devices")
        #expect(CloudSyncStatus.on(lastSynced: now.addingTimeInterval(-300)).line(now: now).hasPrefix("On · synced "))
        #expect(CloudSyncStatus.notSignedIn.short == "Not Signed In")
    }
}

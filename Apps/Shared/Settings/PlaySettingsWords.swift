import Foundation
import TracksCore

/// The words for Settings ▸ Play on iPhone and the Mac's Play pane, worked out from plain
/// values so both read the same in every state and the views only lay them out.
enum PlaySettingsWords {

    // MARK: - Status

    /// Where Play stands, as the hero's status line reads it.
    struct Standing: Equatable {
        var source: MusicSource
        var opening: OpeningTab
        /// Whether Tracks may play Apple Music.
        var allowsAppleMusic: Bool
        /// iPhone's Offline Mode, with how many songs are downloaded. Nil when it's off.
        var offlineSongs: Int?
        /// Songs in your music: files, and every song on your servers.
        var songs: Int
        var servers: Int
        /// The first server with a problem, by name.
        var troubledServer: TroubledServer?
    }

    struct TroubledServer: Equatable {
        var name: String
        var needsPassword: Bool
    }

    static func status(_ standing: Standing) -> (line: String, tone: SettingsTone) {
        switch standing.source {
        case .appleMusic:
            guard standing.allowsAppleMusic else {
                #if os(macOS)
                return (String(localized: "Allow Apple Music in General to play it here."), .attention)
                #else
                return (String(localized: "Allow Apple Music in Settings ▸ Apple Music to play it here."), .attention)
                #endif
            }
            if let offline = standing.offlineSongs {
                let songs = plain(AttributedString(localized: "^[\(offline) downloaded song](inflect: true)"))
                return (String(localized: "Offline Mode · \(songs)"), .plain)
            }
            return (String(localized: "Plays Apple Music · opens to \(openingName(standing.opening))"), .plain)
        case .yourMusic:
            if let server = standing.troubledServer {
                let name = quoted(server.name)
                return server.needsPassword
                    ? (String(localized: "\(name) needs its password"), .attention)
                    : (String(localized: "\(name) can’t be reached"), .attention)
            }
            guard standing.songs > 0 || standing.servers > 0 else {
                return (String(localized: "Add songs or connect a server to start."), .attention)
            }
            let songs = plain(AttributedString(localized: "^[\(standing.songs) song](inflect: true)"))
            return (String(localized: "Plays Your Music · \(songs)"), .plain)
        }
    }

    // MARK: - Source

    /// Each combination is one whole string to translate, rather than pieces put together.
    static func sourceFooter(_ source: MusicSource, quickSwitch: QuickSwitchState) -> String {
        let isAppleMusic = source == .appleMusic
        #if os(macOS)
        switch quickSwitch {
        case .unavailable:
            return isAppleMusic
                ? String(localized: "Listen Now and your library play Apple Music. Choose Your Music to play the FLAC and other files you own, and songs on your own music server.")
                : String(localized: "Listen Now and your library play your own music: files on this Mac, and songs on your servers. Every song is kept in your history, just like Apple Music’s.")
        case .off:
            return isAppleMusic
                ? String(localized: "Listen Now and your library play Apple Music. Choose Your Music to play the FLAC and other files you own, and songs on your own music server. Quick Switch puts both a click away, in Listen Now’s title.")
                : String(localized: "Listen Now and your library play your own music: files on this Mac, and songs on your servers. Every song is kept in your history, just like Apple Music’s. Quick Switch puts both a click away, in Listen Now’s title.")
        case .on:
            return isAppleMusic
                ? String(localized: "Listen Now and your library play Apple Music. Choose Your Music to play the FLAC and other files you own, and songs on your own music server. Click Listen Now’s title to switch. What’s playing carries on until you play something from the other.")
                : String(localized: "Listen Now and your library play your own music: files on this Mac, and songs on your servers. Every song is kept in your history, just like Apple Music’s. Click Listen Now’s title to switch. What’s playing carries on until you play something from the other.")
        }
        #else
        switch quickSwitch {
        case .unavailable:
            return isAppleMusic
                ? String(localized: "Songs come from Apple Music. Choose Your Music to play the FLAC and other files you own, and songs on your own music server.")
                : String(localized: "Songs come from your own music: files on this iPhone and songs on your servers. Every song is kept in your history, just like Apple Music’s.")
        case .off:
            return isAppleMusic
                ? String(localized: "Songs come from Apple Music. Choose Your Music to play the FLAC and other files you own, and songs on your own music server. Quick Switch puts both a tap away, in Play’s title.")
                : String(localized: "Songs come from your own music: files on this iPhone and songs on your servers. Every song is kept in your history, just like Apple Music’s. Quick Switch puts both a tap away, in Play’s title.")
        case .on:
            return isAppleMusic
                ? String(localized: "Songs come from Apple Music. Choose Your Music to play the FLAC and other files you own, and songs on your own music server. Tap Play’s title to switch. What’s playing carries on until you play something from the other, and Play suggests your downloads when you’re offline. To switch with a Focus, add the Tracks filter in Settings ▸ Focus.")
                : String(localized: "Songs come from your own music: files on this iPhone and songs on your servers. Every song is kept in your history, just like Apple Music’s. Tap Play’s title to switch. What’s playing carries on until you play something from the other, and Play suggests your downloads when you’re offline. To switch with a Focus, add the Tracks filter in Settings ▸ Focus.")
        }
        #endif
    }

    enum QuickSwitchState: Equatable {
        /// Only offered with Apple Music allowed and music of your own.
        case unavailable
        case off
        case on
    }

    // MARK: - Around Tracks

    /// Where Tracks opens: "Play" on iPhone, "Listen Now" on the Mac, where Play is the
    /// sidebar's Listen Now.
    static func openingName(_ tab: OpeningTab) -> String {
        switch tab {
        case .summary: String(localized: "Summary")
        #if os(macOS)
        case .play: String(localized: "Listen Now")
        #else
        case .play: String(localized: "Play")
        #endif
        }
    }

    static func openingFooter(_ tab: OpeningTab) -> String {
        #if os(macOS)
        tab == .play
            ? String(localized: "Tracks opens to Listen Now, and Listen Now and Radio come first in the sidebar, as ⌘1 and ⌘2.")
            : String(localized: "Tracks opens to Summary, and your listening comes first in the sidebar, as ⌘1 onwards.")
        #else
        tab == .play
            ? String(localized: "Tracks opens to Play, and Play comes first in the tab bar.")
            : String(localized: "Tracks opens to Summary, and Play comes last in the tab bar.")
        #endif
    }

    /// "Tracks" or "Apple Music"; on the Mac, "Music" is the Music app.
    static func destinationName(_ destination: SongDestination) -> String {
        switch destination {
        case .tracks: String(localized: "Tracks")
        #if os(macOS)
        case .appleMusic: String(localized: "Music")
        #else
        case .appleMusic: String(localized: "Apple Music")
        #endif
        }
    }

    static func destinationFooter(_ destination: SongDestination) -> String {
        #if os(macOS)
        destination == .tracks
            ? String(localized: "Play on a song or album in Your Listening plays it here, in Tracks.")
            : String(localized: "Play on a song or album in Your Listening opens it in the Music app.")
        #else
        destination == .tracks
            ? String(localized: "Play on a song or album in Summary, History and Charts plays it here.")
            : String(localized: "Play on a song or album in Summary, History and Charts opens it in Apple Music.")
        #endif
    }

    /// Shaking iPhone to play.
    static func shakeFooter(_ shakeToPlay: Bool) -> String {
        shakeToPlay
            ? String(localized: "Shake iPhone to play a song you haven’t heard that Tracks thinks you’ll like, with Tracks Radio after it.")
            : String(localized: "Shaking iPhone does nothing in Tracks.")
    }

    /// Why your devices can't be found, and where to fix it.
    static var localNetworkOff: String {
        #if os(macOS)
        String(localized: "Tracks can’t look for them: turn on Tracks in System Settings › Privacy & Security › Local Network.")
        #else
        String(localized: "Tracks can’t look for them: turn on Local Network in Settings › Apps › Tracks.")
        #endif
    }

    // MARK: - Your Music

    static func suggestionFooter(_ mode: SuggestionMode) -> String {
        switch mode {
        case .everything:
            String(localized: "Your servers find songs by the artists you play and artists like them, mixed with songs you have and haven’t played yet. No Apple Music needed.")
        case .onlyYours:
            #if os(macOS)
            String(localized: "Tracks suggests only songs you have, on this Mac or your servers. Nothing new is found for you.")
            #else
            String(localized: "Tracks suggests only songs you have, on this iPhone or your servers. Nothing new is found for you.")
            #endif
        case .off:
            #if os(macOS)
            String(localized: "No suggestions: Listen Now shows your own music and nothing else.")
            #else
            String(localized: "No suggestions: Play shows your own music and nothing else.")
            #endif
        }
    }

    /// iPhone's footer for Downloads and Streaming. The Mac's rows say it in their details.
    static func downloadsFooter(automatic: Bool, wiFi: StreamQuality, cellular: StreamQuality, download: StreamQuality) -> String {
        AudioQualityWords.downloadsFooter(automatic: automatic, wiFi: wiFi.maxBitRate, cellular: cellular.maxBitRate, download: download.maxBitRate)
    }

    /// Show Audio Quality's detail on the Mac, and its sentence in iPhone's footer.
    static func audioQualityDetail(isShown: Bool) -> String {
        AudioQualityWords.showsAudioQuality(isShown)
    }

    /// Move with the Music's detail on the Mac, under the switch.
    static func livingCoverDetail(movesWithMusic: Bool) -> String {
        movesWithMusic
            ? String(localized: "Breathes with the bass, stirs with the snare and glints with the cymbals, at the song’s own pace.")
            : String(localized: "Flows at a calm pace of its own, whatever’s playing.")
    }

    /// Living Cover's footer where Move with the Music has no detail line: iPhone's Settings,
    /// and Stage's choices on both.
    static func livingCoverFooter(movesWithMusic: Bool) -> String {
        movesWithMusic
            ? String(localized: "The cover comes alive and moves with the music: it breathes with the bass, stirs with the snare and glints with the cymbals, and settles when it’s paused.")
            : String(localized: "The cover comes alive: its colours flow and swirl into one another at a calm pace of their own, and settle when it’s paused.")
    }

    // MARK: - Tracks Radio

    /// Where Tracks Radio shows, which depends on the source and on what the layout shows.
    struct RadioPlace: Equatable {
        var source: MusicSource
        var showsForYou: Bool
        var showsSuggestedSongs: Bool
        /// Your Music's suggestions aren't off.
        var suggests: Bool
    }

    /// On iPhone the footer carries it all. The Mac's rows say what each switch does, so its
    /// footer says only where the station is and what Siri plays.
    static func radioFooter(isOn: Bool, place: RadioPlace, downloadsFirst: Bool, deletesAfterPlaying: Bool) -> String {
        #if os(macOS)
        guard isOn else {
            return String(localized: "Siri plays your mix for this time of day when you say “Play music in Tracks.”")
        }
        return [radioWhere(place), String(localized: "Siri plays it when you say “Play music in Tracks.”")]
            .compactMap(\.self)
            .joined(separator: " ")
        #else
        guard isOn else {
            return String(localized: "Tracks Radio is hidden. Siri plays your mix for this time of day when you say “Play music in Tracks.”")
        }
        var lines = [String(localized: "Your own station, from everything you love and new finds like it, picked as it plays.")]
        if let whereItIs = radioWhere(place) {
            lines.append(whereItIs)
        }
        lines.append(String(localized: "Siri plays it when you say “Play music in Tracks.”"))
        guard place.source == .yourMusic, downloadsFirst else { return lines.joined(separator: " ") }
        lines.append(String(localized: "It starts with songs on this iPhone, so it plays at once, and downloads its new finds in the background. They wait in Up Next until they’re here, and you can swipe away any you don’t want."))
        if deletesAfterPlaying {
            lines.append(String(localized: "Each new find’s download goes once it’s played. Keep one from Up Next, or add it to a playlist, and it stays."))
        }
        return lines.joined(separator: " ")
        #endif
    }

    private static func radioWhere(_ place: RadioPlace) -> String? {
        switch place.source {
        case .appleMusic:
            #if os(macOS)
            if place.showsForYou { return String(localized: "It’s in For You, at the top of Listen Now, and on Radio.") }
            if place.showsSuggestedSongs { return String(localized: "It leads Suggested Songs on Listen Now, and it’s on Radio.") }
            return String(localized: "It’s on Radio in the sidebar.")
            #else
            if place.showsForYou { return String(localized: "It’s in For You, at the top of Play.") }
            if place.showsSuggestedSongs { return String(localized: "It leads Suggested Songs, since For You is hidden.") }
            return nil
            #endif
        case .yourMusic:
            #if os(macOS)
            return place.suggests
                ? String(localized: "It leads Suggested Songs on Listen Now, and it’s on Radio.")
                : String(localized: "It’s at the top of Listen Now, and on Radio.")
            #else
            return place.suggests
                ? String(localized: "It leads Suggested Songs.")
                : String(localized: "It’s at the top of Play.")
            #endif
        }
    }

    // MARK: - Content and transitions

    static func explicitFooter(_ allows: Bool) -> String {
        allows
            ? String(localized: "When a song comes in both versions, Tracks plays the explicit one.")
            : String(localized: "Tracks plays clean versions and leaves out songs that only come explicit. On stations, it skips them.")
    }

    static func transitionFooter(_ transition: SongTransition) -> String {
        transition == .crossfade
            ? String(localized: "Each song fades into the next. Songs that run into each other on an album still play without a gap. Starts with the next thing you play.")
            : String(localized: "Each song ends before the next one starts.")
    }

    // MARK: - Layout

    /// "All Shown", or "9 of 12 Shown".
    static func layoutValue(_ layout: PlayLayout) -> String {
        let all = layout.offered.count
        let shown = layout.offered.count(where: layout.isVisible)
        return shown == all
            ? String(localized: "All Shown")
            : String(localized: "\(shown) of \(all) Shown")
    }

    /// For the Mac's row: what the layout adds up to.
    static func layoutDetail(_ layout: PlayLayout) -> String {
        if layout == .standard {
            return String(localized: "Every section, in the standard order.")
        }
        let hidden = layout.offered.count { !layout.isVisible($0) }
        guard hidden > 0 else { return String(localized: "Every section, in your own order.") }
        return plain(AttributedString(localized: "^[\(hidden) section](inflect: true) hidden."))
    }

    // MARK: - Mixes

    /// What the mixes remember from skips and "Suggest Less".
    struct MixMemory: Equatable {
        /// Songs the mixes leave out: skipped early twice lately, or asked to hear less of.
        var leftOut: Int
        var askedLess: Int
        /// Skipped once, so still in the mixes, but one skip from leaving.
        var skippedOnce: Int

        init(leftOut: Int, askedLess: Int, skippedOnce: Int) {
            self.leftOut = leftOut
            self.askedLess = askedLess
            self.skippedOnce = skippedOnce
        }

        init(_ signals: ListeningSignals, now: Date = .now) {
            // Skips and "suggest less" only: blocked artists are a list of their own, which
            // Reset leaves alone.
            var signals = signals
            signals.blocked = BlockedArtists()
            let songs = Set(signals.skips.keys).union(signals.suggestLess)
            let excluded = songs.filter { signals.excludes($0, now: now) }
            leftOut = excluded.count
            askedLess = signals.suggestLess.count
            skippedOnce = songs.count { !excluded.contains($0) && signals.recentSkips(of: $0, now: now) > 0 }
        }

        var isEmpty: Bool { leftOut == 0 && skippedOnce == 0 }
    }

    /// "7 songs left out · 2 you asked to hear less of", for the Mac's row and iPhone's value.
    static func mixDetail(_ memory: MixMemory) -> String {
        guard !memory.isEmpty else { return String(localized: "Nothing skipped yet") }
        guard memory.leftOut > 0 else {
            return plain(AttributedString(localized: "Nothing left out · ^[\(memory.skippedOnce) song](inflect: true) skipped once"))
        }
        let leftOut = plain(AttributedString(localized: "^[\(memory.leftOut) song](inflect: true) left out"))
        guard memory.askedLess > 0 else { return leftOut }
        return String(localized: "\(leftOut) · \(memory.askedLess) you asked to hear less of")
    }

    static func resetMessage(_ memory: MixMemory) -> String {
        guard memory.leftOut > 0 else {
            return String(localized: "Tracks forgets the songs you’ve skipped once. Nothing is left out of your mixes yet.")
        }
        let songs = plain(AttributedString(localized: "^[\(memory.leftOut) song](inflect: true)"))
        return String(localized: "The \(songs) your mixes leave out come back into them, and Tracks forgets every skip.")
    }

    /// The confirmation's button, with the count when songs come back.
    static func resetButton(_ memory: MixMemory) -> String {
        guard memory.leftOut > 0 else { return String(localized: "Reset Mix Suggestions") }
        return plain(AttributedString(localized: "Bring Back ^[\(memory.leftOut) Song](inflect: true)"))
    }

    static var mixesFooter: String {
        #if os(macOS)
        String(localized: "Mixes leave out songs you skip early twice or ask to hear less of. That stays on this Mac.")
        #else
        String(localized: "Mixes leave out songs you skip early twice or ask to hear less of. That stays on this iPhone.")
        #endif
    }

    // MARK: - Helpers

    /// Inflection resolved, for places that show the markup literally: status strings, dialog
    /// titles and messages.
    static func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    /// Curly quotes, so a name reads as a name inside a sentence.
    static func quoted(_ name: String) -> String {
        "\u{201C}\(name)\u{201D}"
    }
}

#if os(macOS)
import Testing
import Foundation
@testable import TracksMusic

/// Escaping titles for AppleScript. A stray quote becomes a script syntax error, which the
/// user sees as "playback failed".
@Suite("Music.app playback scripting")
struct MusicLibraryPlaybackTests {

    @Test("a quoted title cannot break out of the script literal")
    func escapesQuotes() {
        #expect(MusicLibraryPlayback.escape(#"Say "Hello""#) == #"Say \"Hello\""#)
    }

    @Test("backslashes are escaped before quotes, not after")
    func escapesBackslashes() {
        // Quotes first would turn `"` into `\\"`: an escaped backslash, then a bare quote.
        #expect(MusicLibraryPlayback.escape(#"AC\DC"#) == #"AC\\DC"#)
        #expect(MusicLibraryPlayback.escape(#"a\"b"#) == #"a\\\"b"#)
    }

    @Test("ordinary titles are left alone")
    func leavesPlainTitlesAlone() {
        #expect(MusicLibraryPlayback.escape("Nearness of You") == "Nearness of You")
    }
}

/// Matching what Music.app is playing against what Tracks asked for. A false mismatch means
/// the capture is never marked played back and the queue stalls.
@Suite("Now-playing matching")
struct NowPlayingMatchingTests {

    @Test("case and surrounding space do not prevent a match")
    func normalisationIgnoresCaseAndSpace() {
        #expect(MusicAppPlaybackService.normalise("  BUTTERFLIES  ") == MusicAppPlaybackService.normalise("butterflies"))
        #expect(MusicAppPlaybackService.normalise("Doesn't Work") == MusicAppPlaybackService.normalise("DOESN'T WORK"))
    }

    @Test("combining diacritics fold")
    func normalisationFoldsDiacritics() {
        #expect(MusicAppPlaybackService.normalise("Café") == MusicAppPlaybackService.normalise("Cafe"))
    }

    /// `ø`, `ß` and `ł` are letters of their own, so folding keeps them. Fine here, since both
    /// sides come from Apple and spell the artist the same way.
    @Test("a letter that only looks like an accent is not folded")
    func strokedLettersDoNotFold() {
        #expect(MusicAppPlaybackService.normalise("Dølle Jølle") != MusicAppPlaybackService.normalise("Dolle Jolle"))
        #expect(MusicAppPlaybackService.normalise("Dølle Jølle") == MusicAppPlaybackService.normalise("dølle jølle"))
    }

    @Test("different songs still do not match")
    func normalisationKeepsDistinctTitlesDistinct() {
        #expect(MusicAppPlaybackService.normalise("Saltwater") != MusicAppPlaybackService.normalise("Salt Water"))
    }
}
#endif

import Testing
import Foundation
@testable import TracksCore

/// The menu bar label's format string. A label ending in a stray separator or running off
/// the menu bar looks like a broken app, and nothing logs it.
@Suite("Menu bar label format")
struct MenuBarLabelTests {

    @Test("tokens are filled from the song")
    func fillsTokens() {
        #expect(MenuBarLabelFormat.render(
            "{title} \u{2014} {artist}", title: "Saltwater", artist: "Lee Clarke"
        ) == "Saltwater \u{2014} Lee Clarke")
    }

    @Test("every documented token actually resolves")
    func everyTokenResolves() {
        // Settings lists these; one that isn't substituted shows its braces in the menu bar.
        for token in MenuBarLabelFormat.tokens {
            let rendered = MenuBarLabelFormat.render(
                token, title: "T", artist: "A", album: "B", station: "S"
            )
            #expect(!rendered.contains("{"), "\(token) was not substituted")
        }
    }

    @Test("tokens are case-insensitive")
    func tokensIgnoreCase() {
        #expect(MenuBarLabelFormat.render("{TITLE}", title: "Saltwater", artist: "A") == "Saltwater")
    }

    @Test("a separator with nothing beside it is dropped")
    func tidiesDanglingSeparators() {
        #expect(MenuBarLabelFormat.render(
            "{title} \u{2014} {artist}", title: "Saltwater", artist: ""
        ) == "Saltwater")
        #expect(MenuBarLabelFormat.render(
            "{title} \u{2014} {artist}", title: "", artist: "Lee Clarke"
        ) == "Lee Clarke")
    }

    @Test("a format with nothing in it renders nothing")
    func emptyFormatIsEmpty() {
        // Cover with no text is a valid choice.
        #expect(MenuBarLabelFormat.render("", title: "Saltwater", artist: "A").isEmpty)
        #expect(MenuBarLabelFormat.render("{album}", title: "T", artist: "A", album: nil).isEmpty)
    }

    @Test("runs of space left by a missing token collapse")
    func collapsesWhitespace() {
        #expect(MenuBarLabelFormat.render(
            "{title}  {album}  {artist}", title: "Saltwater", artist: "Lee Clarke", album: nil
        ) == "Saltwater Lee Clarke")
    }

    @Test("a long label is cut on a word boundary")
    func truncatesOnAWord() {
        let rendered = MenuBarLabelFormat.render(
            "{title} \u{2014} {artist}",
            title: "Burn The Hard Drive (feat. Mura Masa)",
            artist: "Jade Bird"
        )
        // The first 23 characters are "Burn The Hard Drive (fe". Cutting through the word
        // would give "Burn The Hard Drive (fe…", and cutting at the space without dropping
        // it "Burn The Hard Drive …".
        #expect(rendered == "Burn The Hard Drive…")
        #expect(rendered.count <= MenuBarLabelFormat.characterLimit)
    }

    @Test("a label that fits is left exactly as written")
    func shortLabelUntouched() {
        let rendered = MenuBarLabelFormat.render("{artist}", title: "T", artist: "BANKS")
        #expect(rendered == "BANKS")
    }

    @Test("an unbroken word is still cut to the limit")
    func truncatesWordWithNoSpaces() {
        let long = String(repeating: "a", count: 80)
        let rendered = MenuBarLabelFormat.render("{title}", title: long, artist: "")
        // No space to cut on, so it fills the limit exactly, ellipsis included.
        #expect(rendered == String(repeating: "a", count: MenuBarLabelFormat.characterLimit - 1) + "…")
        #expect(rendered.count == MenuBarLabelFormat.characterLimit)
    }

    @Test("only the artwork styles draw a cover")
    func artworkStyles() {
        #expect(MenuBarLabelStyle.artwork.showsArtwork)
        #expect(MenuBarLabelStyle.artworkAndTitle.showsArtwork)
        #expect(!MenuBarLabelStyle.radio.showsArtwork)
        #expect(!MenuBarLabelStyle.note.showsArtwork)
        #expect(!MenuBarLabelStyle.title.showsArtwork)
        #expect(!MenuBarLabelStyle.custom.showsArtwork)
    }

    @Test("only the two symbol styles draw a symbol")
    func symbolStyles() {
        #expect(MenuBarLabelStyle.radio.symbol == "radio")
        #expect(MenuBarLabelStyle.note.symbol == "music.note")
        for style in [MenuBarLabelStyle.artwork, .artworkAndTitle, .title, .artist, .custom] {
            #expect(style.symbol == nil, "\(style.name) should draw no symbol")
        }
    }

    @Test("only radio has a filled variant, and only while capturing")
    func filledVariant() {
        #expect(MenuBarLabelStyle.radio.symbol(isCapturing: true) == "radio.fill")
        #expect(MenuBarLabelStyle.radio.symbol(isCapturing: false) == "radio")
        #expect(MenuBarLabelStyle.note.symbol(isCapturing: true) == "music.note")
        #expect(MenuBarLabelStyle.title.symbol(isCapturing: true) == nil)
    }

    @Test("with nothing stored, the menu bar shows the note")
    func defaultsToNote() {
        let suite = "com.luke.tracks.tests.\(UUID().uuidString)"
        let settings = CaptureSettings(suiteName: suite)
        defer { ScratchDefaults.remove(suiteName: suite) }

        #expect(MenuBarLabelStyle.default == .note)
        #expect(settings.menuBarLabelStyle == .note)
    }

    @Test("an unknown stored style falls back to the default, and a chosen one is kept")
    func storedStyles() {
        #expect(MenuBarLabelStyle(stored: "nonsense") == .default)
        #expect(MenuBarLabelStyle(stored: nil) == .default)
        #expect(MenuBarLabelStyle(stored: "radio") == .radio)
        #expect(MenuBarLabelStyle(stored: "artworkAndTitle") == .artworkAndTitle)
    }

    /// The stored value from before there were two symbol styles.
    @Test("a stored \"icon\" style still resolves")
    func legacyStyleName() {
        let suite = "com.luke.tracks.tests.\(UUID().uuidString)"
        let settings = CaptureSettings(suiteName: suite)
        defer { ScratchDefaults.remove(suiteName: suite) }

        UserDefaults(suiteName: suite)?.set("icon", forKey: CaptureSettings.menuBarLabelStyleKey)
        #expect(settings.menuBarLabelStyle == .radio)
    }
}

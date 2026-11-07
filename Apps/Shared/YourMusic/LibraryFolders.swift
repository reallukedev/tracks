import Foundation

/// Where your music lives on this device.
nonisolated enum LibraryFolders {
    /// Your files: Documents/Music, which the Files app shows as On My iPhone › Tracks › Music.
    /// On the Mac it's in Tracks’ container, and Show Music Folder opens it in Finder.
    static var music: URL {
        URL.documentsDirectory.appending(path: "Music", directoryHint: .isDirectory)
    }

    /// Songs downloaded from servers. Kept apart from your files, so a download is never
    /// mistaken for one of them, and out of iCloud backup's way: they can be downloaded again.
    static var downloads: URL {
        URL.applicationSupportDirectory.appending(path: "Your Music/Downloads", directoryHint: .isDirectory)
    }

    /// Covers taken from files, by name.
    static var artwork: URL {
        URL.applicationSupportDirectory.appending(path: "Your Music/Artwork", directoryHint: .isDirectory)
    }

    /// What Tracks knows about each file and server, so it doesn't read them all again.
    static var index: URL {
        URL.applicationSupportDirectory.appending(path: "Your Music/Index", directoryHint: .isDirectory)
    }

    static func prepare() {
        for folder in [music, downloads, artwork, index] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var downloads = downloads
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? downloads.setResourceValues(values)
    }
}

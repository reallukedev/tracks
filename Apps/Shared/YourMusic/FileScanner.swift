import Foundation
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers
import TracksCore

/// Reads the Music folder: every playable file, its tags, format and cover. A file already
/// read and unchanged since isn't read again.
nonisolated enum FileScanner {
    /// A file as last read, kept so an unchanged file costs nothing on the next scan.
    struct CachedFile: Codable, Sendable {
        let size: Int64
        let modified: Date
        let track: LocalTrack
    }

    private static var cacheURL: URL { LibraryFolders.index.appending(path: "files.json") }

    static func loadCache() -> [String: CachedFile] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedFile].self, from: data)) ?? [:]
    }

    static func saveCache(_ cache: [String: CachedFile]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// Every playable file in the Music folder, read or remembered.
    @concurrent
    static func scan(previous: [String: CachedFile]) async -> [String: CachedFile] {
        let files = listFiles()
        var result: [String: CachedFile] = [:]
        for file in files {
            if let cached = previous[file.path], cached.size == file.size, cached.modified == file.modified {
                result[file.path] = cached
                continue
            }
            if Task.isCancelled { break }
            let track = await readTrack(at: file.url, path: file.path, addedAt: previous[file.path]?.track.addedAt ?? file.added)
            result[file.path] = CachedFile(size: file.size, modified: file.modified, track: track)
        }
        return result
    }

    private struct ListedFile {
        let url: URL
        let path: String
        let size: Int64
        let modified: Date
        let added: Date
    }

    /// Every playable file under the Music folder, with what says whether it's changed.
    private static func listFiles() -> [ListedFile] {
        let root = LibraryFolders.music
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .addedToDirectoryDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var files: [ListedFile] = []
        for case let url as URL in enumerator {
            guard AudioFormat.playableExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            files.append(ListedFile(url: url, path: relativePath(of: url, in: root), size: Int64(values.fileSize ?? 0), modified: modified, added: values.addedToDirectoryDate ?? modified))
        }
        return files
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let full = url.standardizedFileURL.path(percentEncoded: false)
        let base = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }

    // MARK: - Reading a file

    /// A file's tags, format and cover, with its folders standing in for tags it lacks:
    /// "Artist/Album/01 Title.flac".
    static func readTrack(at url: URL, path: String, addedAt: Date) async -> LocalTrack {
        var tags = Tags()
        if url.pathExtension.lowercased() == "flac" {
            tags = readFLAC(url)
        } else {
            tags = await readWithAVFoundation(url)
        }

        let (fileTitle, fileNumber) = titleAndNumber(fromFileName: url.deletingPathExtension().lastPathComponent)
        let folders = path.split(separator: "/").dropLast().map(String.init)
        let album = tags.album ?? folders.last
        let artist = tags.artist ?? tags.albumArtist ?? (folders.count >= 2 ? folders[folders.count - 2] : nil) ?? String(localized: "Unknown Artist")
        var track = LocalTrack(
            origin: .file(path: path),
            title: tags.title ?? fileTitle,
            artist: artist,
            albumArtist: tags.albumArtist,
            album: album,
            trackNumber: tags.trackNumber ?? fileNumber,
            discNumber: tags.discNumber,
            year: tags.year,
            genre: tags.genre,
            duration: tags.duration,
            format: tags.format ?? AudioFormat(codec: AudioFormat.codec(forExtension: url.pathExtension)),
            addedAt: addedAt
        )
        let picture = tags.picture ?? folderCover(besides: url)
        if let picture {
            track.artwork = saveArtwork(picture.data, mimeType: picture.mimeType, for: track.albumKey)
        }
        return track
    }

    struct Tags {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var trackNumber: Int?
        var discNumber: Int?
        var year: Int?
        var genre: String?
        var duration: TimeInterval?
        var format: AudioFormat?
        var picture: (data: Data, mimeType: String)?
    }

    private static func readFLAC(_ url: URL) -> Tags {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Tags() }
        defer { try? handle.close() }
        guard let metadata = try? FLACMetadata.read({ offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }) else { return Tags() }
        return Tags(
            title: metadata.title,
            artist: metadata.artist,
            albumArtist: metadata.albumArtist,
            album: metadata.album,
            trackNumber: metadata.trackNumber,
            discNumber: metadata.discNumber,
            year: metadata.year,
            genre: metadata.genre,
            duration: metadata.duration,
            format: metadata.format,
            picture: metadata.picture.map { ($0.data, $0.mimeType) }
        )
    }

    private static func readWithAVFoundation(_ url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        var tags = Tags()
        if let (duration, common) = try? await asset.load(.duration, .commonMetadata) {
            tags.duration = duration.seconds.isFinite ? duration.seconds : nil
            func string(_ identifier: AVMetadataIdentifier) async -> String? {
                let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: identifier).first
                let value = try? await item?.load(.stringValue)
                return value.flatMap { $0.isEmpty ? nil : $0 }
            }
            tags.title = await string(.commonIdentifierTitle)
            tags.artist = await string(.commonIdentifierArtist)
            tags.album = await string(.commonIdentifierAlbumName)
            if let date = await string(.commonIdentifierCreationDate) {
                tags.year = Int(date.prefix(4))
            }
            if let item = AVMetadataItem.metadataItems(from: common, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await item.load(.dataValue) {
                tags.picture = (data, data.starts(with: [0x89, 0x50]) ? "image/png" : "image/jpeg")
            }
        }
        if let all = try? await asset.load(.metadata) {
            for item in all {
                let key = item.identifier?.rawValue ?? ""
                if key.hasSuffix("/trkn") || key.hasSuffix("/TRCK") {
                    if let number = try? await item.load(.numberValue) {
                        tags.trackNumber = number.intValue
                    } else if let text = try? await item.load(.stringValue) {
                        tags.trackNumber = Int(text.prefix { $0.isNumber })
                    }
                } else if tags.genre == nil, key.hasSuffix("/©gen") || key.hasSuffix("/TCON") || key.hasSuffix("/gnre") {
                    tags.genre = try? await item.load(.stringValue)
                } else if tags.albumArtist == nil, key.hasSuffix("/aART") || key.hasSuffix("/TPE2") {
                    tags.albumArtist = try? await item.load(.stringValue)
                }
            }
        }
        tags.format = await format(of: asset, fileExtension: url.pathExtension)
        return tags
    }

    private static func format(of asset: AVURLAsset, fileExtension: String) async -> AudioFormat {
        var format = AudioFormat(codec: AudioFormat.codec(forExtension: fileExtension))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let (descriptions, rate) = try? await track.load(.formatDescriptions, .estimatedDataRate),
              let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { return format }
        format.sampleRate = Int(basic.mSampleRate)
        switch basic.mFormatID {
        case kAudioFormatAppleLossless:
            format.codec = "ALAC"
            format.bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][Int(basic.mFormatFlags)]
        case kAudioFormatLinearPCM:
            format.bitDepth = Int(basic.mBitsPerChannel)
        default:
            format.bitRate = rate > 0 ? Int((rate / 1_000).rounded()) : nil
        }
        return format
    }

    /// "03 - Night Drive" is track 3, "Night Drive".
    static func titleAndNumber(fromFileName name: String) -> (String, Int?) {
        let digits = name.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return (name, nil) }
        let rest = name.dropFirst(digits.count).drop { " -._".contains($0) }
        return rest.isEmpty ? (name, nil) : (String(rest), number)
    }

    /// The usual cover files beside a song: cover.jpg, folder.jpg, front.png and the like.
    private static func folderCover(besides url: URL) -> (data: Data, mimeType: String)? {
        let folder = url.deletingLastPathComponent()
        for name in ["cover", "folder", "front", "album", "Cover", "Folder", "Front", "AlbumArt"] {
            for ext in ["jpg", "jpeg", "png"] {
                let candidate = folder.appending(path: "\(name).\(ext)")
                if let data = try? Data(contentsOf: candidate) {
                    return (data, ext == "png" ? "image/png" : "image/jpeg")
                }
            }
        }
        return nil
    }

    /// Keeps a cover once per album, named for the album.
    private static func saveArtwork(_ data: Data, mimeType: String, for albumKey: String) -> LocalTrack.Artwork {
        let hash = SHA256.hash(data: Data(albumKey.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        let name = hash + (mimeType.contains("png") ? ".png" : ".jpg")
        let destination = LibraryFolders.artwork.appending(path: name)
        if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try? data.write(to: destination, options: .atomic)
        }
        return .file(name: name)
    }

    // MARK: - Bringing files in

    struct ImportResult: Sendable {
        var added = 0
        var skipped = 0
    }

    /// Copies songs into the Music folder: files as they are, folders with what's inside them,
    /// their own folders kept. A song already there is left alone; a different one of the
    /// same name is kept beside it.
    @concurrent
    static func importItems(_ urls: [URL]) async -> ImportResult {
        importNow(urls)
    }

    private static func importNow(_ urls: [URL]) -> ImportResult {
        var result = ImportResult()
        let root = LibraryFolders.music
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isFolder {
                let base = url.deletingLastPathComponent()
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in enumerator where isImportable(file) {
                    let relative = relativePath(of: file, in: base)
                    copy(file, to: root.appending(path: relative), result: &result)
                }
            } else if isImportable(url) {
                copy(url, to: root.appending(path: url.lastPathComponent), result: &result)
            }
        }
        return result
    }

    /// Songs, and the cover images that go with them.
    private static func isImportable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if AudioFormat.playableExtensions.contains(ext) { return true }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return ["jpg", "jpeg", "png"].contains(ext) && ["cover", "folder", "front", "album", "albumart"].contains(stem)
    }

    /// Songs are counted, not the covers that come with them.
    private static func copy(_ source: URL, to destination: URL, result: inout ImportResult) {
        let manager = FileManager.default
        let isSong = AudioFormat.playableExtensions.contains(destination.pathExtension.lowercased())
        try? manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourcePath = source.path(percentEncoded: false)
        let folder = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        let suffix = destination.pathExtension.isEmpty ? "" : "." + destination.pathExtension
        var target = destination
        var number = 1
        while manager.fileExists(atPath: target.path(percentEncoded: false)) {
            // This very file, brought in before.
            if manager.contentsEqual(atPath: target.path(percentEncoded: false), andPath: sourcePath) {
                if isSong { result.skipped += 1 }
                return
            }
            // Another file of the same name, from another album say: this one goes beside it.
            number += 1
            target = folder.appending(path: "\(stem) \(number)\(suffix)")
        }
        do {
            try manager.copyItem(at: source, to: target)
            if isSong { result.added += 1 }
        } catch {
            if isSong { result.skipped += 1 }
        }
    }
}

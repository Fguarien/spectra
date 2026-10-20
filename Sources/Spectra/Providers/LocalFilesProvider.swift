import Foundation
import AVFoundation

/// Plays music from a folder on disk — the replacement for Music.app. Builds a
/// Plex-shaped tree from the directory layout (Artist / Album / Track, the
/// common export shape), so every browse, search and playback path in the app
/// works without caring that the source is local.
///
/// The app is not sandboxed (ad-hoc codesign, no entitlements), so a plain path
/// is enough — no security-scoped bookmark. The "token" stored per account in
/// the Keychain is the folder path. Ratings are kept locally in AppDatabase via
/// AppModel; server hooks (scrobble, remote playlists, related artists) are
/// inert here.
final class LocalFilesProvider: MusicProvider {
    let kind: ProviderKind = .local
    let capabilities = ProviderCapabilities(
        canRate: true, canScrobbleToServer: false, canEditPlaylists: false,
        canSearch: true, canHaveSimilar: false
    )

    private let root: URL
    let displayName: String

    /// The scanned library, built off the main actor and assigned once.
    private struct Index {
        var artists: [PlexMetadata] = []
        var albumsByArtist: [String: [PlexMetadata]] = [:]
        var tracksByAlbum: [String: [PlexMetadata]] = [:]
        var allTracks: [PlexMetadata] = []
    }
    private var index = Index()

    private static let audioExts: Set<String> =
        ["mp3", "m4a", "aac", "flac", "alac", "aif", "aiff", "wav", "caf", "mp4", "m4b"]
    private static let coverNames: Set<String> = ["cover", "folder", "front", "album", "albumart"]
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "webp"]

    init(rootPath: String) {
        root = URL(fileURLWithPath: rootPath, isDirectory: true)
        displayName = root.lastPathComponent.isEmpty ? "Local Files" : root.lastPathComponent
    }

    func connect() async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw LocalFilesError.noFolder(root.path)
        }
        let root = self.root
        index = try await Task.detached(priority: .userInitiated) {
            try await LocalFilesProvider.buildIndex(root: root)
        }.value
    }

    // MARK: browse

    func artists() async throws -> [PlexMetadata] { index.artists }
    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata] {
        index.albumsByArtist[artist.ratingKey] ?? []
    }
    func tracks(of album: PlexMetadata) async throws -> [PlexMetadata] {
        index.tracksByAlbum[album.ratingKey] ?? []
    }

    /// Every scanned file, dated by the file's creation (= when it entered the
    /// folder, what « Recently Added » sorts on) and timed from the file
    /// itself (the folder layout carries no duration). Eight files at a time.
    func catalog() async throws -> [PlexMetadata] {
        let urls = index.allTracks.map { URL(fileURLWithPath: $0.ratingKey) }
        // withBounded returns in completion order: key the answers by path.
        let info = await Self.withBounded(urls, limit: 8) { url -> (String, Int?, Int?) in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let d = try? await AVURLAsset(url: url).load(.duration)
            let ms = d.flatMap { $0.isNumeric ? Int($0.seconds * 1000) : nil }
            return (url.path, created.map { Int($0.timeIntervalSince1970) }, ms)
        }
        let byPath = Dictionary(info.map { ($0.0, ($0.1, $0.2)) }, uniquingKeysWith: { a, _ in a })
        return index.allTracks.map { t in
            var t = t
            if let i = byPath[t.ratingKey] {
                t.addedAt = i.0
                if let ms = i.1, ms > 0 { t.duration = ms }
            }
            return t
        }
    }

    // MARK: playlists / related — not supported for a plain folder (yet)

    func playlists() async throws -> [PlexMetadata] { [] }
    func playlistItems(id: String) async throws -> [PlexMetadata] { [] }
    func relatedArtists(ratingKey: String) async throws -> [PlexMetadata] { [] }

    // MARK: search (in-memory, case-insensitive substring)

    func search(_ query: String) async throws -> [HubContainerResponse.Hub] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let artists = index.artists.filter { $0.title.lowercased().contains(q) }
        let albums = index.albumsByArtist.values.flatMap { $0 }.filter { $0.title.lowercased().contains(q) }
        let tracks = index.allTracks.filter { $0.title.lowercased().contains(q) }
        var hubs: [HubContainerResponse.Hub] = []
        if !artists.isEmpty { hubs.append(.init(title: "Artists", type: "artist", items: Array(artists.prefix(50)))) }
        if !albums.isEmpty { hubs.append(.init(title: "Albums", type: "album", items: Array(albums.prefix(50)))) }
        if !tracks.isEmpty { hubs.append(.init(title: "Tracks", type: "track", items: Array(tracks.prefix(100)))) }
        return hubs
    }

    // MARK: URLs

    func playableURL(for m: PlexMetadata) -> URL? {
        guard let path = m.firstPartKey else { return nil }
        return URL(fileURLWithPath: path)
    }
    /// Already on disk — nothing to download.
    func downloadURL(for m: PlexMetadata) -> URL? { nil }
    func artworkURL(_ thumb: String?, size: Int) -> URL? {
        guard let thumb else { return nil }
        return thumb.hasPrefix("http") ? URL(string: thumb) : URL(fileURLWithPath: thumb)
    }

    // MARK: server hooks — inert for a local source

    func rate(ratingKey: String, stars: Int) async throws {}            // AppDatabase stores it
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {}
    func createPlaylist(title: String, trackRatingKeys: [String]) async throws {
        throw ProviderError.notImplemented(.local)
    }
    func addToPlaylist(id: String, trackRatingKeys: [String]) async throws {
        throw ProviderError.notImplemented(.local)
    }
    func deletePlaylist(id: String) async throws {
        throw ProviderError.notImplemented(.local)
    }

    // MARK: scanning

    private struct Resolved: Sendable {
        let url: URL; let artist: String; let album: String
        let title: String; let index: Int?; let thumb: String?
    }

    private static func buildIndex(root: URL) async throws -> Index {
        let fm = FileManager.default
        let rootComps = root.standardizedFileURL.pathComponents

        let relDirs: @Sendable (URL) -> [String] = { url in
            let comps = url.standardizedFileURL.pathComponents
            guard comps.count > rootComps.count else { return [] }
            return Array(comps.dropFirst(rootComps.count).dropLast())
        }

        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else { return Index() }
        let all = en.allObjects.compactMap { $0 as? URL }   // snapshot before any await

        // Folder covers (cover.jpg / folder.png …) keyed by "artist/album".
        var coverFor: [String: String] = [:]
        var audio: [URL] = []
        for url in all {
            let ext = url.pathExtension.lowercased()
            if imageExts.contains(ext) {
                if coverNames.contains(url.deletingPathExtension().lastPathComponent.lowercased()) {
                    let dirs = relDirs(url)
                    let a = dirs.first ?? "Unknown Artist"
                    let al = dirs.count >= 2 ? dirs.last! : (dirs.first ?? "Unknown Album")
                    coverFor["\(a)/\(al)"] = url.path
                }
            } else if audioExts.contains(ext) {
                audio.append(url)
            }
        }

        // Resolve every audio file (bounded concurrency). Structured libraries use
        // the path; loose files use embedded tags then an "Artist - Title" name.
        // Artwork = a folder cover, else the file's own embedded image.
        let covers = coverFor
        let resolved = await withBounded(audio, limit: 16) { url -> Resolved in
            let dirs = relDirs(url)
            if let artist = dirs.first {
                let album = dirs.count >= 2 ? dirs.last! : artist
                let (idx, title) = parseTrackName(url.deletingPathExtension().lastPathComponent)
                let thumb: String?
                if let folderCover = covers["\(artist)/\(album)"] { thumb = folderCover }
                else { thumb = await embeddedArtwork(url) }
                return Resolved(url: url, artist: artist, album: album, title: title, index: idx, thumb: thumb)
            }
            let base = url.deletingPathExtension().lastPathComponent
            let (tags, art) = await readTagsAndArt(url)
            let artist: String, album: String, title: String
            if let a = tags.artist, !a.isEmpty {
                artist = a; album = tags.album ?? "Singles"; title = (tags.title?.isEmpty == false ? tags.title! : base)
            } else if let (a, t) = splitArtistTitle(base) {
                artist = a; album = tags.album ?? "Singles"; title = t
            } else {
                artist = "Unknown Artist"; album = tags.album ?? "Unknown Album"; title = (tags.title?.isEmpty == false ? tags.title! : base)
            }
            return Resolved(url: url, artist: artist, album: album, title: title, index: nil, thumb: art)
        }

        struct T { let url: URL; let index: Int?; let title: String; let thumb: String? }
        var tree: [String: [String: [T]]] = [:]
        for r in resolved {
            tree[r.artist, default: [:]][r.album, default: []]
                .append(T(url: r.url, index: r.index, title: r.title, thumb: r.thumb))
        }

        let ci: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var out = Index()
        for artist in tree.keys.sorted(by: ci) {
            let artistKey = "lart:\(artist)"
            var albumRows: [PlexMetadata] = []
            for album in tree[artist]!.keys.sorted(by: ci) {
                let albumKey = "lalb:\(artist)\u{1}\(album)"
                let sorted = tree[artist]![album]!.sorted {
                    ($0.index ?? Int.max, $0.title.lowercased()) < ($1.index ?? Int.max, $1.title.lowercased())
                }
                let albumThumb = sorted.compactMap(\.thumb).first
                let trackRows = sorted.map { t in
                    PlexMetadata(ratingKey: t.url.path, title: t.title, type: "track",
                                 thumb: t.thumb ?? albumThumb, parentTitle: album, grandparentTitle: artist,
                                 parentRatingKey: albumKey, grandparentRatingKey: artistKey,
                                 index: t.index, filePath: t.url.path,
                                 fileContainer: t.url.pathExtension.lowercased())
                }
                out.tracksByAlbum[albumKey] = trackRows
                out.allTracks.append(contentsOf: trackRows)
                albumRows.append(
                    PlexMetadata(ratingKey: albumKey, title: album, type: "album",
                                 thumb: albumThumb, parentTitle: artist, grandparentTitle: artist,
                                 parentRatingKey: artistKey, grandparentRatingKey: artistKey,
                                 leafCount: trackRows.count)
                )
            }
            out.albumsByArtist[artistKey] = albumRows
            let artistThumb = albumRows.compactMap(\.thumb).first
            out.artists.append(
                PlexMetadata(ratingKey: artistKey, title: artist, type: "artist", thumb: artistThumb)
            )
        }
        return out
    }

    /// Run `work` over `items` with at most `limit` concurrent tasks.
    private static func withBounded<T: Sendable>(_ items: [URL], limit: Int,
                                                 _ work: @escaping @Sendable (URL) async -> T) async -> [T] {
        var out: [T] = []; out.reserveCapacity(items.count)
        var i = 0
        while i < items.count {
            let slice = Array(items[i..<min(i + limit, items.count)])
            let part = await withTaskGroup(of: T.self) { group -> [T] in
                for u in slice { group.addTask { await work(u) } }
                var acc: [T] = []
                for await r in group { acc.append(r) }
                return acc
            }
            out.append(contentsOf: part)
            i += limit
        }
        return out
    }

    /// Splits "01 - Song", "01. Song", "01 Song" into (1, "Song"). Falls back to
    /// the whole name when there's no leading track number.
    private static func parseTrackName(_ raw: String) -> (Int?, String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(digits) else { return (nil, s) }
        let rest = s.dropFirst(digits.count).drop { " .-_)".contains($0) }
        let title = String(rest).trimmingCharacters(in: .whitespaces)
        return (n, title.isEmpty ? s : title)
    }

    /// Extract and cache a file's embedded cover; returns the cached file path.
    private static func embeddedArtwork(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata),
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
              let data = (try? await item.load(.dataValue)) ?? nil else { return nil }
        return await ArtworkCache.shared.storeEmbedded(data, key: url.path)
    }

    /// Read common artist/album/title tags plus embedded artwork (best-effort).
    private static func readTagsAndArt(_ url: URL)
        async -> ((artist: String?, album: String?, title: String?), String?) {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return ((nil, nil, nil), nil) }
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first else { return nil }
            return (try? await item.load(.stringValue)) ?? nil
        }
        let artist = await value(.commonIdentifierArtist)
        let album = await value(.commonIdentifierAlbumName)
        let title = await value(.commonIdentifierTitle)
        var artPath: String?
        if let art = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = (try? await art.load(.dataValue)) ?? nil {
            artPath = await ArtworkCache.shared.storeEmbedded(data, key: url.path)
        }
        return ((artist, album, title), artPath)
    }

    /// "Artist - Title" → ("Artist", "Title"), splitting on the first " - ".
    private static func splitArtistTitle(_ name: String) -> (String, String)? {
        guard let r = name.range(of: " - ") else { return nil }
        let a = name[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
        let t = name[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return (a.isEmpty || t.isEmpty) ? nil : (a, t)
    }
}

enum LocalFilesError: LocalizedError {
    case noFolder(String)
    var errorDescription: String? {
        switch self {
        case .noFolder(let p): return "Music folder not found: \(p)"
        }
    }
}

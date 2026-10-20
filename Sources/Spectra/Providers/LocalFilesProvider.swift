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
            try LocalFilesProvider.buildIndex(root: root)
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
        thumb.map { URL(fileURLWithPath: $0) }
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

    private static func buildIndex(root: URL) throws -> Index {
        let fm = FileManager.default
        let rootComps = root.standardizedFileURL.pathComponents

        func relComponents(_ url: URL) -> [String] {
            let comps = url.standardizedFileURL.pathComponents
            guard comps.count > rootComps.count else { return [url.lastPathComponent] }
            return Array(comps.dropFirst(rootComps.count))
        }

        struct Track { let url: URL; let index: Int?; let title: String }
        var tree: [String: [String: [Track]]] = [:]       // artist → album → tracks
        var coverFor: [String: String] = [:]              // "artist/album" → image path

        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil,
                                     options: [.skipsHiddenFiles]) else {
            return Index()
        }
        for case let url as URL in en {
            let ext = url.pathExtension.lowercased()
            let dirs = relComponents(url).dropLast()
            let artist = dirs.first ?? "Unknown Artist"
            let album = dirs.count >= 2 ? dirs.last! : (dirs.first ?? "Unknown Album")

            if imageExts.contains(ext) {
                if coverNames.contains(url.deletingPathExtension().lastPathComponent.lowercased()) {
                    coverFor["\(artist)/\(album)"] = url.path
                }
                continue
            }
            guard audioExts.contains(ext) else { continue }
            let (idx, title) = parseTrackName(url.deletingPathExtension().lastPathComponent)
            tree[artist, default: [:]][album, default: []].append(Track(url: url, index: idx, title: title))
        }

        let ci: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var out = Index()
        for artist in tree.keys.sorted(by: ci) {
            let artistKey = "lart:\(artist)"
            var albumRows: [PlexMetadata] = []
            for album in tree[artist]!.keys.sorted(by: ci) {
                let albumKey = "lalb:\(artist)\u{1}\(album)"
                let cover = coverFor["\(artist)/\(album)"]
                let sorted = tree[artist]![album]!.sorted {
                    ($0.index ?? Int.max, $0.title.lowercased()) < ($1.index ?? Int.max, $1.title.lowercased())
                }
                let trackRows = sorted.map { t in
                    PlexMetadata(ratingKey: t.url.path, title: t.title, type: "track",
                                 thumb: cover, parentTitle: album, grandparentTitle: artist,
                                 parentRatingKey: albumKey, grandparentRatingKey: artistKey,
                                 index: t.index, filePath: t.url.path,
                                 fileContainer: t.url.pathExtension.lowercased())
                }
                out.tracksByAlbum[albumKey] = trackRows
                out.allTracks.append(contentsOf: trackRows)
                albumRows.append(
                    PlexMetadata(ratingKey: albumKey, title: album, type: "album",
                                 thumb: cover, parentTitle: artist, grandparentTitle: artist,
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
}

enum LocalFilesError: LocalizedError {
    case noFolder(String)
    var errorDescription: String? {
        switch self {
        case .noFolder(let p): return "Music folder not found: \(p)"
        }
    }
}

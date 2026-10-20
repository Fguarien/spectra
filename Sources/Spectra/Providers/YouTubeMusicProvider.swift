import Foundation

/// YouTube Music — the KASET replacement. Two moving parts:
/// • **browse + search** go through `ytmusic_bridge.py` (ytmusicapi) which emits a
///   normalized `{"items":[…]}` shape, so the personal library (artists, albums,
///   playlists, Liked Music) is navigable.
/// • **playback** resolves each track's stream with `yt-dlp` (videoId → itag-140
///   m4a → AVPlayer), async per play.
///
/// The account token is the path to the ytmusicapi `browser.json` the user
/// produced from their logged-in session; the venv Python and the bridge script
/// live beside it (…/spectra-ytmusic/venv/bin/python, …/ytmusic_bridge.py).
/// With no auth file the provider still does anonymous search + play via yt-dlp.
///
/// ToS note: yt-dlp/ytmusicapi vs. YouTube is contrary to YouTube's ToS (as KASET
/// was). Personal listening only.
final class YouTubeMusicProvider: MusicProvider {
    let kind: ProviderKind = .youtubeMusic
    let capabilities = ProviderCapabilities(
        canRate: true, canScrobbleToServer: false, canEditPlaylists: false,
        canSearch: true, canHaveSimilar: false, resolvesStreamLazily: true
    )

    private let authPath: String?       // browser.json, or nil for anonymous
    private var ytdlp = "/usr/local/bin/yt-dlp"
    private var python: String?         // venv python beside the bridge
    private var bridge: String?         // ytmusic_bridge.py

    init(authPath: String?) {
        self.authPath = (authPath?.isEmpty ?? true) ? nil : authPath
    }

    var displayName: String { "YouTube Music" }
    private var hasBridge: Bool { python != nil && bridge != nil }

    func connect() async throws {
        guard let bin = Self.findYtDlp() else { throw YTError.noBinary }
        ytdlp = bin
        // Locate the ytmusicapi bridge: beside the auth file, else the default dir.
        let dir = authPath.map { ($0 as NSString).deletingLastPathComponent }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Developer/spectra-ytmusic")
        let py = (dir as NSString).appendingPathComponent("venv/bin/python")
        let br = (dir as NSString).appendingPathComponent("ytmusic_bridge.py")
        if FileManager.default.isExecutableFile(atPath: py), FileManager.default.fileExists(atPath: br) {
            python = py; bridge = br
        }
    }

    // MARK: browse (via the bridge; empty when it isn't available)

    func artists() async throws -> [PlexMetadata] {
        try await bridgeItems("library_artists").map { $0.asMetadata() }
    }
    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata] {
        guard let id = Self.strip(artist.ratingKey, "ytA:") else { return [] }
        return try await bridgeItems("artist_albums", id).map { $0.asMetadata() }
    }
    func tracks(of album: PlexMetadata) async throws -> [PlexMetadata] {
        guard let id = Self.strip(album.ratingKey, "ytB:") else { return [] }
        return try await bridgeItems("album_tracks", id).map { $0.asMetadata(albumTitle: album.title) }
    }
    func playlists() async throws -> [PlexMetadata] {
        try await bridgeItems("playlists").map { $0.asMetadata() }
    }
    func playlistItems(id: String) async throws -> [PlexMetadata] {
        guard let pid = Self.strip(id, "ytP:") else { return [] }
        return try await bridgeItems("playlist_tracks", pid).map { $0.asMetadata() }
    }
    func relatedArtists(ratingKey: String) async throws -> [PlexMetadata] { [] }

    // MARK: search — bridge (richer) if present, else yt-dlp

    func search(_ query: String) async throws -> [HubContainerResponse.Hub] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if hasBridge {
            let tracks = (try? await bridgeItems("search", q))?.map { $0.asMetadata() } ?? []
            return tracks.isEmpty ? [] : [.init(title: "Songs", type: "track", items: tracks)]
        }
        return try await searchViaYtDlp(q)
    }

    // MARK: URLs

    func playableURL(for m: PlexMetadata) -> URL? { nil }   // async path (lazy)

    func resolveStreamURL(for m: PlexMetadata) async -> URL? {
        guard let id = Self.strip(m.ratingKey, "yt:") else { return nil }
        guard let out = try? await runYtDlp(["-f", "140/bestaudio[ext=m4a]/bestaudio",
                                             "-g", "--no-warnings", id]) else { return nil }
        return out.split(separator: "\n").first.flatMap { URL(string: String($0)) }
    }

    func downloadURL(for m: PlexMetadata) -> URL? { nil }

    /// A plain GET of the `-g` URL is refused (HTTP 403, measured 2026-10-20):
    /// googlevideo wants yt-dlp's chunked range requests. Let yt-dlp write it.
    func downloadFile(for m: PlexMetadata, to dest: URL) async throws {
        guard let id = Self.strip(m.ratingKey, "yt:") else { throw YTError.ytdlp("not a track") }
        _ = try await runYtDlp(["-q", "--no-warnings", "--no-part", "--force-overwrites",
                                "-f", "140/bestaudio[ext=m4a]/bestaudio", "-o", dest.path, id])
    }
    func artworkURL(_ thumb: String?, size: Int) -> URL? { thumb.flatMap { URL(string: $0) } }

    // MARK: server hooks — inert

    func rate(ratingKey: String, stars: Int) async throws {}
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {}
    func createPlaylist(title: String, trackRatingKeys: [String]) async throws { throw ProviderError.notImplemented(.youtubeMusic) }
    func addToPlaylist(id: String, trackRatingKeys: [String]) async throws { throw ProviderError.notImplemented(.youtubeMusic) }
    func deletePlaylist(id: String) async throws { throw ProviderError.notImplemented(.youtubeMusic) }

    // MARK: bridge plumbing

    private func bridgeItems(_ cmd: String, _ arg: String? = nil) async throws -> [BridgeItem] {
        guard let python, let bridge else { return [] }
        var args = [bridge, authPath ?? "-", cmd]
        if let arg { args.append(arg) }
        let out = try await runProcess(python, args)
        guard let data = out.data(using: .utf8),
              let resp = try? JSONDecoder().decode(BridgeResponse.self, from: data) else { return [] }
        if let err = resp.error { throw YTError.ytdlp(err) }
        return resp.items ?? []
    }

    // MARK: yt-dlp plumbing

    private static func findYtDlp() -> String? {
        for p in ["/usr/local/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private static func strip(_ ratingKey: String, _ prefix: String) -> String? {
        ratingKey.hasPrefix(prefix) ? String(ratingKey.dropFirst(prefix.count)) : nil
    }

    private func searchViaYtDlp(_ q: String) async throws -> [HubContainerResponse.Hub] {
        let out = try await runYtDlp(["-J", "--flat-playlist", "--no-warnings", "ytsearch25:\(q)"])
        guard let data = out.data(using: .utf8),
              let result = try? JSONDecoder().decode(YTFlatSearch.self, from: data) else { return [] }
        let tracks: [PlexMetadata] = (result.entries ?? []).compactMap { e in
            guard let id = e.id, let title = e.title else { return nil }
            return PlexMetadata(ratingKey: "yt:\(id)", title: title, type: "track",
                                thumb: e.thumbnails?.last?.url, grandparentTitle: e.channel ?? e.uploader,
                                duration: Int((e.duration ?? 0) * 1000))
        }
        return tracks.isEmpty ? [] : [.init(title: "Songs", type: "track", items: tracks)]
    }

    private func runYtDlp(_ args: [String]) async throws -> String { try await runProcess(ytdlp, args) }

    /// Run a binary off the main actor. stdout and stderr are drained
    /// concurrently so neither pipe can fill and stall the child.
    private func runProcess(_ binary: String, _ args: [String]) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            final class Box { var data = Data() }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let errBox = Box()
            let errQueue = DispatchQueue(label: "spectra.proc.err")
            errQueue.async { errBox.data = err.fileHandleForReading.readDataToEndOfFile() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            errQueue.sync {}   // ensure stderr fully read
            guard p.terminationStatus == 0 else {
                let msg = String(data: errBox.data, encoding: .utf8) ?? ""
                throw YTError.ytdlp(String(msg.prefix(300)))
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}

// MARK: - bridge JSON (normalized by ytmusic_bridge.py)

private struct BridgeResponse: Decodable {
    let items: [BridgeItem]?
    let error: String?
}

private struct BridgeItem: Decodable {
    let id: String
    let title: String?
    let subtitle: String?
    let type: String
    let thumb: String?
    let duration: Int?
    let year: String?

    /// Map the normalized item to the app's Plex-shaped interchange model.
    func asMetadata(albumTitle: String? = nil) -> PlexMetadata {
        switch type {
        case "artist":
            return PlexMetadata(ratingKey: "ytA:\(id)", title: title ?? "Artist", type: "artist", thumb: thumb)
        case "album":
            return PlexMetadata(ratingKey: "ytB:\(id)", title: title ?? "Album", type: "album",
                                thumb: thumb, parentTitle: subtitle, grandparentTitle: subtitle,
                                year: year.flatMap { Int($0) })
        case "playlist":
            return PlexMetadata(ratingKey: "ytP:\(id)", title: title ?? "Playlist", type: "playlist", thumb: thumb)
        default:  // track
            return PlexMetadata(ratingKey: "yt:\(id)", title: title ?? "Track", type: "track",
                                thumb: thumb, parentTitle: albumTitle, grandparentTitle: subtitle,
                                duration: (duration ?? 0) * 1000)
        }
    }
}

// MARK: - yt-dlp flat search JSON (anonymous fallback)

private struct YTFlatSearch: Decodable { let entries: [YTEntry]? }
private struct YTEntry: Decodable {
    let id: String?
    let title: String?
    let channel: String?
    let uploader: String?
    let duration: Double?
    let thumbnails: [YTThumbnail]?
}
private struct YTThumbnail: Decodable { let url: String? }

enum YTError: LocalizedError {
    case noBinary
    case ytdlp(String)
    var errorDescription: String? {
        switch self {
        case .noBinary:
            return "yt-dlp was not found. Install the macOS build at /usr/local/bin/yt-dlp."
        case .ytdlp(let m):
            return "YouTube Music error: \(m)"
        }
    }
}

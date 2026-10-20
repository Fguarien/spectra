import Foundation

/// Plays from YouTube Music — the replacement for KASET. Shells out to the
/// `yt-dlp` binary (a self-contained macOS build, with `deno` as the JS runtime
/// so extraction stays current). The app is not sandboxed, so spawning a
/// `Process` is allowed.
///
/// v1 is **search + play** (KASET's core: find a song, play it). Browsing your
/// personal library, artists and albums needs an authenticated YouTube Music
/// session and is a later increment; `cookiesPath` (a Netscape cookies.txt)
/// is already threaded through for when it lands.
///
/// Note (unspoken truth): this uses yt-dlp against YouTube, which is contrary
/// to YouTube's ToS — same as KASET did. It's for personal listening only.
final class YouTubeMusicProvider: MusicProvider {
    let kind: ProviderKind = .youtubeMusic
    let capabilities = ProviderCapabilities(
        canRate: true, canScrobbleToServer: false, canEditPlaylists: false,
        canSearch: true, canHaveSimilar: false, resolvesStreamLazily: true
    )

    private let cookiesPath: String?
    private var binary = "/usr/local/bin/yt-dlp"

    init(cookiesPath: String?) {
        self.cookiesPath = (cookiesPath?.isEmpty ?? true) ? nil : cookiesPath
    }

    var displayName: String { "YouTube Music" }

    func connect() async throws {
        guard let bin = Self.findBinary() else { throw YTError.noBinary }
        binary = bin
    }

    // MARK: browse — v1 has no authenticated library browse yet

    func artists() async throws -> [PlexMetadata] { [] }
    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata] { [] }
    func tracks(of album: PlexMetadata) async throws -> [PlexMetadata] { [] }
    func playlists() async throws -> [PlexMetadata] { [] }
    func playlistItems(id: String) async throws -> [PlexMetadata] { [] }
    func relatedArtists(ratingKey: String) async throws -> [PlexMetadata] { [] }

    // MARK: search

    func search(_ query: String) async throws -> [HubContainerResponse.Hub] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let out = try await run(["-J", "--flat-playlist", "--no-warnings", "--ignore-errors",
                                 "ytsearch25:\(q)"])
        guard let data = out.data(using: .utf8),
              let result = try? JSONDecoder().decode(YTSearchResult.self, from: data) else { return [] }
        let tracks: [PlexMetadata] = (result.entries ?? []).compactMap { e in
            guard let id = e.id, let title = e.title else { return nil }
            return PlexMetadata(
                ratingKey: "yt:\(id)", title: title, type: "track",
                thumb: e.thumbnails?.last?.url,                     // a full https URL
                grandparentTitle: e.channel ?? e.uploader,
                duration: Int((e.duration ?? 0) * 1000)
            )
        }
        return tracks.isEmpty ? [] : [.init(title: "Songs", type: "track", items: tracks)]
    }

    // MARK: URLs

    /// Sync path unused — YouTube needs async resolution (`resolvesStreamLazily`).
    func playableURL(for m: PlexMetadata) -> URL? { nil }

    func resolveStreamURL(for m: PlexMetadata) async -> URL? {
        guard let id = Self.videoID(m.ratingKey) else { return nil }
        guard let out = try? await run(["-f", "140/bestaudio[ext=m4a]/bestaudio",
                                        "-g", "--no-warnings", id]) else { return nil }
        return out.split(separator: "\n").first.flatMap { URL(string: String($0)) }
    }

    func downloadURL(for m: PlexMetadata) -> URL? { nil }
    /// YouTube thumbnails are already absolute URLs stored in `thumb`.
    func artworkURL(_ thumb: String?, size: Int) -> URL? { thumb.flatMap { URL(string: $0) } }

    // MARK: server hooks — inert

    func rate(ratingKey: String, stars: Int) async throws {}
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {}
    func createPlaylist(title: String, trackRatingKeys: [String]) async throws { throw ProviderError.notImplemented(.youtubeMusic) }
    func addToPlaylist(id: String, trackRatingKeys: [String]) async throws { throw ProviderError.notImplemented(.youtubeMusic) }
    func deletePlaylist(id: String) async throws { throw ProviderError.notImplemented(.youtubeMusic) }

    // MARK: yt-dlp plumbing

    private static func findBinary() -> String? {
        for p in ["/usr/local/bin/yt-dlp", "/opt/homebrew/bin/yt-dlp"] where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private static func videoID(_ ratingKey: String) -> String? {
        ratingKey.hasPrefix("yt:") ? String(ratingKey.dropFirst(3)) : nil
    }

    /// Run yt-dlp off the main actor and capture stdout. stdout is drained before
    /// `waitUntilExit` to avoid a full-pipe deadlock on large JSON.
    private func run(_ args: [String]) async throws -> String {
        let bin = binary
        let cookies = cookiesPath
        return try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            var a = args
            if let cookies { a += ["--cookies", cookies] }
            p.arguments = a
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw YTError.ytdlp(String(msg.prefix(300)))
            }
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}

// MARK: - yt-dlp JSON

private struct YTSearchResult: Decodable { let entries: [YTEntry]? }
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

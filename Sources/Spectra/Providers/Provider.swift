import Foundation

/// A music source Spectra can browse and play from. Phase-2 foundation: the
/// Plex client is the first implementation; Local Files and YouTube Music
/// (yt-dlp) follow. Models are Plex-shaped (`PlexMetadata`) and used as the
/// internal interchange — future providers synthesise rows in the same shape.
enum ProviderKind: String, Codable, Hashable, CaseIterable {
    case plex, local, youtubeMusic

    var label: String {
        switch self {
        case .plex: return "Plex"
        case .local: return "Local Files"
        case .youtubeMusic: return "YouTube Music"
        }
    }

    var systemImage: String {
        switch self {
        case .plex: return "server.rack"
        case .local: return "folder"
        case .youtubeMusic: return "play.rectangle"
        }
    }

    /// All three providers are wired up (Plex, Local Files, YouTube Music).
    var isImplemented: Bool { true }
}

/// What a provider can do, so the UI can hide actions a source doesn't support.
struct ProviderCapabilities {
    var canRate = false
    var canScrobbleToServer = false
    var canEditPlaylists = false
    var canSearch = false
    var canHaveSimilar = false
    /// The stream URL must be resolved asynchronously at play time (a network
    /// round-trip, e.g. yt-dlp for YouTube Music) rather than built synchronously.
    var resolvesStreamLazily = false
}

protocol MusicProvider: AnyObject {
    var displayName: String { get }
    var kind: ProviderKind { get }
    var capabilities: ProviderCapabilities { get }

    func connect() async throws

    func artists() async throws -> [PlexMetadata]
    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata]
    func tracks(of album: PlexMetadata) async throws -> [PlexMetadata]
    func playlists() async throws -> [PlexMetadata]
    func playlistItems(id: String) async throws -> [PlexMetadata]
    func search(_ query: String) async throws -> [HubContainerResponse.Hub]
    func relatedArtists(ratingKey: String) async throws -> [PlexMetadata]

    /// Best playback URL for a track (native stream or a transcode). Synchronous
    /// for providers that can build the URL directly (Plex, Local Files).
    func playableURL(for m: PlexMetadata) -> URL?
    /// Resolve the real stream URL, possibly via a network call (streaming
    /// providers). Defaults to the synchronous `playableURL`.
    func resolveStreamURL(for m: PlexMetadata) async -> URL?
    /// Original-quality URL for offline download (nil if not downloadable).
    func downloadURL(for m: PlexMetadata) -> URL?
    func artworkURL(_ thumb: String?, size: Int) -> URL?

    func rate(ratingKey: String, stars: Int) async throws
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int) async

    func createPlaylist(title: String, trackRatingKeys: [String]) async throws
    func addToPlaylist(id: String, trackRatingKeys: [String]) async throws
    func deletePlaylist(id: String) async throws
}

extension MusicProvider {
    func resolveStreamURL(for m: PlexMetadata) async -> URL? { playableURL(for: m) }
}

enum ProviderError: LocalizedError {
    case notImplemented(ProviderKind)
    var errorDescription: String? {
        switch self {
        case .notImplemented(let k): return "\(k.label) support is not available yet."
        }
    }
}

enum ProviderFactory {
    static func make(for account: Account, token: String) -> any MusicProvider {
        switch account.kind {
        case .plex: return PlexProvider(token: token)
        case .local: return LocalFilesProvider(rootPath: token)   // token = folder path
        case .youtubeMusic: return YouTubeMusicProvider(authPath: token.isEmpty ? nil : token)
        }
    }
}

/// Placeholder for a provider kind not built yet (phases B/C). Connecting
/// surfaces a clear error instead of crashing.
final class UnimplementedProvider: MusicProvider {
    let kind: ProviderKind
    var displayName: String { kind.label }
    var capabilities = ProviderCapabilities()
    init(kind: ProviderKind) { self.kind = kind }

    func connect() async throws { throw ProviderError.notImplemented(kind) }
    func artists() async throws -> [PlexMetadata] { [] }
    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata] { [] }
    func tracks(of album: PlexMetadata) async throws -> [PlexMetadata] { [] }
    func playlists() async throws -> [PlexMetadata] { [] }
    func playlistItems(id: String) async throws -> [PlexMetadata] { [] }
    func search(_ query: String) async throws -> [HubContainerResponse.Hub] { [] }
    func relatedArtists(ratingKey: String) async throws -> [PlexMetadata] { [] }
    func playableURL(for m: PlexMetadata) -> URL? { nil }
    func downloadURL(for m: PlexMetadata) -> URL? { nil }
    func artworkURL(_ thumb: String?, size: Int) -> URL? { nil }
    func rate(ratingKey: String, stars: Int) async throws {}
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {}
    func createPlaylist(title: String, trackRatingKeys: [String]) async throws {}
    func addToPlaylist(id: String, trackRatingKeys: [String]) async throws {}
    func deletePlaylist(id: String) async throws {}
}

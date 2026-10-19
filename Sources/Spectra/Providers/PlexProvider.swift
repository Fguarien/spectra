import Foundation

/// The Plex implementation of `MusicProvider` — wraps `PlexClient` and remembers
/// the first music section so `artists()` needs no section argument.
final class PlexProvider: MusicProvider {
    let kind: ProviderKind = .plex
    let capabilities = ProviderCapabilities(
        canRate: true, canScrobbleToServer: true, canEditPlaylists: true,
        canSearch: true, canHaveSimilar: true
    )

    private let client: PlexClient
    private var firstSectionKey: String?

    init(token: String) { client = PlexClient(accountToken: token) }

    var displayName: String { client.serverName }

    func connect() async throws {
        try await client.discoverServer()
        firstSectionKey = try await client.musicSections().first?.key
    }

    func artists() async throws -> [PlexMetadata] {
        guard let key = firstSectionKey else { return [] }
        return try await client.artists(sectionKey: key)
    }

    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata] {
        try await client.children(ratingKey: artist.ratingKey)
    }

    func tracks(of album: PlexMetadata) async throws -> [PlexMetadata] {
        try await client.children(ratingKey: album.ratingKey)
    }

    func playlists() async throws -> [PlexMetadata] { try await client.playlists() }
    func playlistItems(id: String) async throws -> [PlexMetadata] { try await client.playlistItems(id: id) }
    func search(_ query: String) async throws -> [HubContainerResponse.Hub] { try await client.search(query) }
    func relatedArtists(ratingKey: String) async throws -> [PlexMetadata] { try await client.relatedArtists(ratingKey: ratingKey) }

    func playableURL(for m: PlexMetadata) -> URL? {
        if AudioCapability.canPlayNatively(m.codec) {
            return m.firstPartKey.flatMap { client.streamURL(partKey: $0) }
        }
        return client.transcodeURL(ratingKey: m.ratingKey)   // ape, wma, …
    }

    func downloadURL(for m: PlexMetadata) -> URL? {
        m.firstPartKey.flatMap { client.streamURL(partKey: $0) }
    }

    func artworkURL(_ thumb: String?, size: Int) -> URL? { client.imageURL(thumb: thumb, size: size) }

    func rate(ratingKey: String, stars: Int) async throws { try await client.rate(ratingKey: ratingKey, stars: stars) }
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {
        await client.reportTimeline(ratingKey: ratingKey, state: state, timeMs: timeMs, durationMs: durationMs)
    }

    func createPlaylist(title: String, trackRatingKeys: [String]) async throws {
        _ = try await client.createPlaylist(title: title, trackRatingKeys: trackRatingKeys)
    }
    func addToPlaylist(id: String, trackRatingKeys: [String]) async throws {
        try await client.addToPlaylist(id: id, trackRatingKeys: trackRatingKeys)
    }
    func deletePlaylist(id: String) async throws { try await client.deletePlaylist(id: id) }
}

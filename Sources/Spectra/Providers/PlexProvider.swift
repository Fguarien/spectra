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
    /// Every music library of the server (a server can have several:
    /// « Classique », « Musique »…). Only the first was read before v2.0.3.
    private var sectionKeys: [String] = []

    init(token: String) { client = PlexClient(accountToken: token) }

    var displayName: String { client.serverName }

    func connect() async throws {
        try await client.discoverServer()
        sectionKeys = try await client.musicSections().map(\.key)
    }

    func artists() async throws -> [PlexMetadata] {
        var out: [PlexMetadata] = []
        for key in sectionKeys { out += try await client.artists(sectionKey: key) }
        return out
    }

    func albums(of artist: PlexMetadata) async throws -> [PlexMetadata] {
        try await client.children(ratingKey: artist.ratingKey)
    }

    func tracks(of album: PlexMetadata) async throws -> [PlexMetadata] {
        try await client.children(ratingKey: album.ratingKey)
    }

    /// Whole section in two calls: tracks, then albums for genre / year / cover.
    func catalog() async throws -> [PlexMetadata] {
        var tracks: [PlexMetadata] = [], albums: [PlexMetadata] = []
        for key in sectionKeys {
            async let t = client.allItems(sectionKey: key, type: 10)
            async let a = client.allItems(sectionKey: key, type: 9)
            tracks += try await t
            albums += try await a
        }
        let byAlbum = Dictionary(albums.map { ($0.ratingKey, $0) }, uniquingKeysWith: { a, _ in a })
        return tracks.map { t in
            var t = t
            if let a = t.parentRatingKey.flatMap({ byAlbum[$0] }) {
                if t.Genre == nil { t.Genre = a.Genre }
                if t.parentYear == nil { t.parentYear = a.year }
                if t.parentThumb == nil { t.parentThumb = a.thumb }
            }
            return t
        }
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

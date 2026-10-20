import Foundation

/// Talks to plex.tv (resource discovery) and to a chosen Plex Media Server
/// (library browsing, search, playlists, ratings, stream + transcode URLs).
/// Server + per-server access token are resolved once at sign-in and held here.
final class PlexClient {
    private let session = URLSession(configuration: .default)
    private let accountToken: String

    private(set) var baseURL: URL?
    private(set) var serverToken: String?
    private(set) var serverName: String = ""
    private(set) var machineIdentifier: String = ""   // for playlist `uri` building

    init(accountToken: String) { self.accountToken = accountToken }

    // MARK: resource discovery

    func discoverServer() async throws {
        var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!)
        PlexIdentity.headers(token: accountToken).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, _) = try await session.data(for: req)
        let resources = try JSONDecoder().decode([PlexResource].self, from: data)
        guard let server = resources.first(where: { $0.isServer && $0.owned })
                ?? resources.first(where: { $0.isServer }) else {
            throw PlexError.noServer
        }
        serverName = server.name
        serverToken = server.accessToken ?? accountToken
        machineIdentifier = server.clientIdentifier
        // Prefer a direct local connection, then direct remote, then relay.
        let ordered = server.connections.sorted { a, b in
            func rank(_ c: PlexConnection) -> Int { c.relay ? 2 : (c.local ? 0 : 1) }
            return rank(a) < rank(b)
        }
        guard let chosen = ordered.first, let url = URL(string: chosen.uri) else { throw PlexError.noServer }
        baseURL = url
    }

    // MARK: request helpers

    private func components(_ path: String, query: [URLQueryItem] = []) throws -> URLComponents {
        guard let baseURL, let token = serverToken else { throw PlexError.notReady }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var q = comps.queryItems ?? []
        q.append(contentsOf: query)
        q.append(URLQueryItem(name: "X-Plex-Token", value: token))
        comps.queryItems = q
        return comps
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let comps = try components(path, query: query)
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        PlexIdentity.headers(token: serverToken).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Fire-and-get for state-changing verbs (PUT/POST/DELETE). Returns raw data
    /// (some endpoints answer with a MediaContainer, most with empty body).
    @discardableResult
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let comps = try components(path, query: query)
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        PlexIdentity.headers(token: serverToken).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PlexError.http(http.statusCode)
        }
        return data
    }

    // MARK: library browsing

    func musicSections() async throws -> [PlexSection] {
        let r = try await get("library/sections", as: MediaContainerResponse<PlexSection>.self)
        return r.items.filter { $0.type == "artist" }
    }

    func artists(sectionKey: String) async throws -> [PlexMetadata] {
        try await get("library/sections/\(sectionKey)/all", query: [.init(name: "type", value: "8")],
                      as: MediaContainerResponse<PlexMetadata>.self).items
    }

    /// Every row of one type in a section (9 = albums, 10 = tracks), paged so a
    /// large library never arrives as one multi-megabyte response.
    func allItems(sectionKey: String, type: Int, pageSize: Int = 2000) async throws -> [PlexMetadata] {
        var out: [PlexMetadata] = []
        var start = 0
        while true {
            let page = try await get("library/sections/\(sectionKey)/all", query: [
                .init(name: "type", value: String(type)),
                .init(name: "X-Plex-Container-Start", value: String(start)),
                .init(name: "X-Plex-Container-Size", value: String(pageSize)),
            ], as: MediaContainerResponse<PlexMetadata>.self).items
            out += page
            if page.count < pageSize { return out }
            start += pageSize
        }
    }

    func children(ratingKey: String) async throws -> [PlexMetadata] {
        try await get("library/metadata/\(ratingKey)/children", as: MediaContainerResponse<PlexMetadata>.self).items
    }

    // MARK: search (task #3)

    func search(_ query: String, limit: Int = 30) async throws -> [HubContainerResponse.Hub] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let r = try await get("hubs/search",
                              query: [.init(name: "query", value: query), .init(name: "limit", value: String(limit))],
                              as: HubContainerResponse.self)
        // Keep music hubs only (artist/album/track), drop empty ones.
        return r.hubs.filter { ["artist", "album", "track"].contains($0.type ?? "") && !$0.items.isEmpty }
    }

    // MARK: similar artists (task #4)

    func relatedArtists(ratingKey: String) async throws -> [PlexMetadata] {
        // Plex surfaces "Related Artists" in the item's related hubs.
        let r = try? await get("library/metadata/\(ratingKey)/related", as: HubContainerResponse.self)
        let fromHubs = (r?.hubs ?? []).flatMap { $0.items }.filter { $0.type == "artist" }
        if !fromHubs.isEmpty { return fromHubs }
        // Fallback: the sonically-similar endpoint.
        let s = try? await get("library/metadata/\(ratingKey)/similar", as: MediaContainerResponse<PlexMetadata>.self)
        return s?.items ?? []
    }

    // MARK: ratings (task #1) — Plex 0…10 scale (5 stars = 2 points each)

    func rate(ratingKey: String, stars: Int) async throws {
        let value = max(0, min(5, stars)) * 2
        try await send("PUT", ":/rate", query: [
            .init(name: "identifier", value: "com.plexapp.plugins.library"),
            .init(name: "key", value: ratingKey),
            .init(name: "rating", value: String(value)),
        ])
    }

    // MARK: playlists (task #2)

    func playlists() async throws -> [PlexMetadata] {
        try await get("playlists", query: [.init(name: "playlistType", value: "audio")],
                      as: MediaContainerResponse<PlexMetadata>.self).items
    }

    func playlistItems(id: String) async throws -> [PlexMetadata] {
        try await get("playlists/\(id)/items", as: MediaContainerResponse<PlexMetadata>.self).items
    }

    private func itemURI(ratingKeys: [String]) -> String {
        let keys = ratingKeys.joined(separator: ",")
        return "server://\(machineIdentifier)/com.plexapp.plugins.library/library/metadata/\(keys)"
    }

    /// Create an audio playlist seeded with tracks; returns the new ratingKey.
    @discardableResult
    func createPlaylist(title: String, trackRatingKeys: [String]) async throws -> String? {
        let data = try await send("POST", "playlists", query: [
            .init(name: "type", value: "audio"),
            .init(name: "title", value: title),
            .init(name: "smart", value: "0"),
            .init(name: "uri", value: itemURI(ratingKeys: trackRatingKeys)),
        ])
        let decoded = try? JSONDecoder().decode(MediaContainerResponse<PlexMetadata>.self, from: data)
        return decoded?.items.first?.ratingKey
    }

    func addToPlaylist(id: String, trackRatingKeys: [String]) async throws {
        try await send("PUT", "playlists/\(id)/items",
                       query: [.init(name: "uri", value: itemURI(ratingKeys: trackRatingKeys))])
    }

    /// Remove one item from a playlist (playlistItemID is the per-playlist id).
    func removeFromPlaylist(id: String, playlistItemID: String) async throws {
        try await send("DELETE", "playlists/\(id)/items/\(playlistItemID)")
    }

    func deletePlaylist(id: String) async throws {
        try await send("DELETE", "playlists/\(id)")
    }

    // MARK: media URLs

    func streamURL(partKey: String) -> URL? {
        guard let baseURL, let token = serverToken else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent(partKey), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        return comps.url
    }

    /// Universal-transcode URL producing MP3 that AVFoundation always decodes —
    /// used for `ape` and other codecs with no native support (task #7).
    func transcodeURL(ratingKey: String) -> URL? {
        guard let baseURL, let token = serverToken else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("music/:/transcode/universal/start.mp3"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "path", value: "/library/metadata/\(ratingKey)"),
            .init(name: "protocol", value: "http"),
            .init(name: "musicBitrate", value: "320"),
            .init(name: "X-Plex-Client-Identifier", value: PlexIdentity.clientIdentifier),
            .init(name: "X-Plex-Token", value: token),
        ]
        return comps.url
    }

    func imageURL(thumb: String?, size: Int = 300) -> URL? {
        guard let thumb, let baseURL, let token = serverToken else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent("photo/:/transcode"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "width", value: String(size)),
            URLQueryItem(name: "height", value: String(size)),
            URLQueryItem(name: "url", value: thumb),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        return comps.url
    }

    /// Best-effort scrobble/progress report to Plex (timeline endpoint).
    func reportTimeline(ratingKey: String, state: String, timeMs: Int, durationMs: Int) async {
        guard let baseURL, let token = serverToken else { return }
        var comps = URLComponents(url: baseURL.appendingPathComponent(":/timeline"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "duration", value: String(durationMs)),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        PlexIdentity.headers(token: token).forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        _ = try? await session.data(for: req)
    }
}

enum PlexError: Error { case noServer, notReady, http(Int) }

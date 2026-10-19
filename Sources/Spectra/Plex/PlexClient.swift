import Foundation

/// Talks to plex.tv (resource discovery) and to a chosen Plex Media Server
/// (library browsing + stream URLs). Server + per-server access token are
/// resolved once at sign-in and held here.
final class PlexClient {
    private let session = URLSession(configuration: .default)
    private let accountToken: String

    private(set) var baseURL: URL?
    private(set) var serverToken: String?
    private(set) var serverName: String = ""

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
        // Prefer a direct local connection, then direct remote, then relay.
        let ordered = server.connections.sorted { a, b in
            func rank(_ c: PlexConnection) -> Int { c.relay ? 2 : (c.local ? 0 : 1) }
            return rank(a) < rank(b)
        }
        guard let chosen = ordered.first, let url = URL(string: chosen.uri) else { throw PlexError.noServer }
        baseURL = url
    }

    // MARK: generic GET

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        guard let baseURL, let token = serverToken else { throw PlexError.notReady }
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        var q = comps.queryItems ?? []
        q.append(URLQueryItem(name: "X-Plex-Token", value: token))
        comps.queryItems = q
        var req = URLRequest(url: comps.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: library

    func musicSections() async throws -> [PlexSection] {
        let r = try await get("library/sections", as: MediaContainerResponse<PlexSection>.self)
        return r.items.filter { $0.type == "artist" }
    }

    func artists(sectionKey: String) async throws -> [PlexMetadata] {
        try await get("library/sections/\(sectionKey)/all?type=8", as: MediaContainerResponse<PlexMetadata>.self).items
    }

    func children(ratingKey: String) async throws -> [PlexMetadata] {
        try await get("library/metadata/\(ratingKey)/children", as: MediaContainerResponse<PlexMetadata>.self).items
    }

    // MARK: media URLs

    func streamURL(partKey: String) -> URL? {
        guard let baseURL, let token = serverToken else { return nil }
        var comps = URLComponents(url: baseURL.appendingPathComponent(partKey), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
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

enum PlexError: Error { case noServer, notReady }

import Foundation

/// plex.tv PIN ("link") authentication flow.
/// 1. request a PIN  → get {id, code}
/// 2. open app.plex.tv/auth#?...&code=... in the browser, user approves
/// 3. poll the PIN until its authToken is populated
struct PlexPIN: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

enum PlexAuthError: Error { case badResponse, timedOut }

final class PlexAuth {
    private let session = URLSession(configuration: .ephemeral)

    func requestPIN() async throws -> PlexPIN {
        var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins?strong=true")!)
        req.httpMethod = "POST"
        PlexIdentity.headers().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 201 else { throw PlexAuthError.badResponse }
        return try JSONDecoder().decode(PlexPIN.self, from: data)
    }

    /// The URL to open so the user can approve the link in their browser.
    func authURL(code: String) -> URL {
        var c = URLComponents(string: "https://app.plex.tv/auth")!
        c.fragment = "?clientID=\(PlexIdentity.clientIdentifier)" +
            "&code=\(code)" +
            "&context%5Bdevice%5D%5Bproduct%5D=\(PlexIdentity.product)"
        return c.url!
    }

    /// Polls until the PIN carries a token or the timeout elapses.
    func pollForToken(pin: PlexPIN, timeout: TimeInterval = 300) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(pin.id)?code=\(pin.code)")!)
            PlexIdentity.headers().forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, _) = try await session.data(for: req)
            if let polled = try? JSONDecoder().decode(PlexPIN.self, from: data),
               let token = polled.authToken, !token.isEmpty {
                return token
            }
        }
        throw PlexAuthError.timedOut
    }
}

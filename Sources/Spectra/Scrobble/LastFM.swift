import Foundation
import AppKit
import CryptoKit

/// Last.fm scrobbler (phase 2 D). Desktop auth flow: auth.getToken → the user
/// approves in the browser → auth.getSession. Now-playing is sent when a track
/// starts; a scrobble is queued once it has really been PLAYED for half its
/// length or 4 minutes (Last.fm rule, tracks > 30 s), and the queue survives
/// offline periods and restarts.
///
/// Secrets: API key, shared secret and session key live in the Keychain only.
/// The key pair arrives once through a provisioning file (see
/// `importProvisioningFile`), imported then deleted at launch.
@MainActor
final class LastFM: ObservableObject {
    static let shared = LastFM()

    @Published private(set) var username: String? = UserDefaults.standard.string(forKey: Keys.user)
    @Published private(set) var hasAPIKey = false
    @Published private(set) var pendingCount = 0
    @Published var status: String?
    @Published var scrobblePlex: Bool = UserDefaults.standard.bool(forKey: Keys.scrobblePlex) {
        didSet { UserDefaults.standard.set(scrobblePlex, forKey: Keys.scrobblePlex) }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }

    private enum Keys {
        static let apiKey = "lastfm.apiKey", secret = "lastfm.secret", session = "lastfm.session"
        static let user = "lastfm.user", queue = "lastfm.queue"
        static let scrobblePlex = "lastfm.scrobblePlex", enabled = "lastfm.enabled"
    }

    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private let session = URLSession(configuration: .ephemeral)
    private var timer: Timer?

    // Current-track bookkeeping.
    private var trackedKey: String?      // id|url of the track being measured
    private var trackedStart = 0         // unix time it started
    private var playedSeconds = 0.0
    private var scrobbled = false
    private let tick = 2.0

    struct Scrobble: Codable { let artist, track, album: String; let timestamp, duration: Int }

    private var queue: [Scrobble] {
        get { (UserDefaults.standard.data(forKey: Keys.queue)).flatMap { try? JSONDecoder().decode([Scrobble].self, from: $0) } ?? [] }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Keys.queue)
            pendingCount = newValue.count
        }
    }

    // MARK: lifecycle

    func start() {
        importProvisioningFile()
        hasAPIKey = Keychain.get(account: Keys.apiKey) != nil && Keychain.get(account: Keys.secret) != nil
        pendingCount = queue.count
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        Task { await flush() }
    }

    /// `~/Library/Application Support/Spectra/lastfm-provision.json`
    /// = {"api_key": "...", "shared_secret": "..."} — imported then deleted.
    private func importProvisioningFile() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectra", isDirectory: true)
        let file = dir.appendingPathComponent("lastfm-provision.json")
        guard let data = try? Data(contentsOf: file) else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let key = obj["api_key"], let secret = obj["shared_secret"], !key.isEmpty, !secret.isEmpty
        else { status = "Last.fm provisioning file was invalid and has been removed."; return }
        Keychain.set(key, account: Keys.apiKey)
        Keychain.set(secret, account: Keys.secret)
    }

    // MARK: auth

    func connect() {
        guard hasAPIKey else { status = "No Last.fm API key installed."; return }
        status = "Waiting for approval in the browser…"
        Task {
            do {
                let tokenJSON = try await call("auth.getToken", [:], post: false)
                guard let token = tokenJSON["token"] as? String,
                      let apiKey = Keychain.get(account: Keys.apiKey) else { throw LastFMError.api("no token") }
                var c = URLComponents(string: "https://www.last.fm/api/auth/")!
                c.queryItems = [.init(name: "api_key", value: apiKey), .init(name: "token", value: token)]
                NSWorkspace.shared.open(c.url!)
                let deadline = Date().addingTimeInterval(300)
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(3))
                    // Error 14 = token not yet authorised: keep polling.
                    guard let s = try? await call("auth.getSession", ["token": token], post: false),
                          let sess = s["session"] as? [String: Any],
                          let key = sess["key"] as? String else { continue }
                    Keychain.set(key, account: Keys.session)
                    let name = sess["name"] as? String
                    UserDefaults.standard.set(name, forKey: Keys.user)
                    username = name
                    status = nil
                    await flush()
                    return
                }
                status = "Last.fm approval timed out."
            } catch {
                status = "Last.fm: \(error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        Keychain.delete(account: Keys.session)
        UserDefaults.standard.removeObject(forKey: Keys.user)
        username = nil
    }

    // MARK: playback tracking

    private func shouldScrobble(_ t: PlayableTrack) -> Bool {
        guard enabled, t.durationMs > 30_000, !t.artist.isEmpty else { return false }
        if t.sourceKind == .plex && !scrobblePlex { return false }   // Plex may scrobble server-side
        return true
    }

    private func poll() {
        let player = AudioPlayer.shared
        guard let t = player.current else { trackedKey = nil; return }
        let key = "\(t.id)|\(t.url.absoluteString)"
        if key != trackedKey {
            trackedKey = key
            trackedStart = Int(Date().timeIntervalSince1970)
            playedSeconds = 0
            scrobbled = false
            if shouldScrobble(t) { Task { await nowPlaying(t) } }
            return
        }
        guard player.isPlaying, !scrobbled else { return }
        playedSeconds += tick
        let threshold = min(Double(t.durationMs) / 2000.0, 240)
        if playedSeconds >= threshold, shouldScrobble(t) {
            scrobbled = true
            var q = queue
            q.append(Scrobble(artist: t.artist, track: t.title, album: t.album,
                              timestamp: trackedStart, duration: t.durationMs / 1000))
            queue = q
            Task { await flush() }
        }
    }

    private func nowPlaying(_ t: PlayableTrack) async {
        guard Keychain.get(account: Keys.session) != nil else { return }
        var p = ["artist": t.artist, "track": t.title, "duration": String(t.durationMs / 1000)]
        if !t.album.isEmpty { p["album"] = t.album }
        _ = try? await call("track.updateNowPlaying", p, post: true, signedSession: true)
    }

    /// Send queued scrobbles, 50 at a time; keep them on failure.
    func flush() async {
        guard Keychain.get(account: Keys.session) != nil else { return }
        while !queue.isEmpty {
            let batch = Array(queue.prefix(50))
            var p: [String: String] = [:]
            for (i, s) in batch.enumerated() {
                p["artist[\(i)]"] = s.artist
                p["track[\(i)]"] = s.track
                p["timestamp[\(i)]"] = String(s.timestamp)
                p["duration[\(i)]"] = String(s.duration)
                if !s.album.isEmpty { p["album[\(i)]"] = s.album }
            }
            do {
                _ = try await call("track.scrobble", p, post: true, signedSession: true)
                queue = Array(queue.dropFirst(batch.count))
            } catch LastFMError.code(let c, let msg) where c == 9 {
                disconnect(); status = "Last.fm session expired — reconnect. (\(msg))"; return
            } catch {
                status = "Last.fm offline — \(queue.count) scrobble(s) queued."; return
            }
        }
        status = nil
    }

    // MARK: similar tracks (Radio ♥)

    struct Similar { let artist: String; let title: String }

    /// `track.getSimilar`, falling back to the top tracks of `artist.getSimilar`
    /// when Last.fm has no track-level data (frequent for recent releases).
    func similarTracks(artist: String, title: String, limit: Int) async -> [Similar] {
        if let j = try? await call("track.getSimilar",
                                   ["artist": artist, "track": title, "limit": String(limit), "autocorrect": "1"], post: false),
           let list = (j["similartracks"] as? [String: Any])?["track"] as? [[String: Any]], !list.isEmpty {
            return list.compactMap { t in
                guard let name = t["name"] as? String, let a = (t["artist"] as? [String: Any])?["name"] as? String else { return nil }
                return Similar(artist: a, title: name)
            }
        }
        let perArtist = min(10, max(5, (limit + 14) / 15))
        guard let j = try? await call("artist.getSimilar", ["artist": artist, "limit": "15", "autocorrect": "1"], post: false),
              let artists = (j["similarartists"] as? [String: Any])?["artist"] as? [[String: Any]] else { return [] }
        var out: [Similar] = []
        for a in artists.compactMap({ $0["name"] as? String }) {
            guard let tj = try? await call("artist.getTopTracks", ["artist": a, "limit": String(perArtist)], post: false),
                  let tracks = (tj["toptracks"] as? [String: Any])?["track"] as? [[String: Any]] else { continue }
            out += tracks.compactMap { ($0["name"] as? String).map { Similar(artist: a, title: $0) } }
        }
        return out
    }

    // MARK: transport

    enum LastFMError: LocalizedError {
        case api(String), code(Int, String)
        var errorDescription: String? {
            switch self {
            case .api(let m): return m
            case .code(let c, let m): return "error \(c): \(m)"
            }
        }
    }

    /// Signed call (every method used here is signed). `signedSession` adds sk.
    private func call(_ method: String, _ params: [String: String], post: Bool,
                      signedSession: Bool = false) async throws -> [String: Any] {
        guard let apiKey = Keychain.get(account: Keys.apiKey),
              let secret = Keychain.get(account: Keys.secret) else { throw LastFMError.api("no API key") }
        var p = params
        p["method"] = method
        p["api_key"] = apiKey
        if signedSession {
            guard let sk = Keychain.get(account: Keys.session) else { throw LastFMError.api("not connected") }
            p["sk"] = sk
        }
        let sigBase = p.keys.sorted().map { $0 + p[$0]! }.joined() + secret
        p["api_sig"] = Insecure.MD5.hash(data: Data(sigBase.utf8)).map { String(format: "%02x", $0) }.joined()
        p["format"] = "json"

        // Strict encoding: URLComponents leaves '&', '=' and '+' unescaped in
        // values, which would split "Simon & Garfunkel" into two parameters.
        // ASCII only: `.alphanumerics` would let "é" through unencoded.
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let enc = { (v: String) in v.addingPercentEncoding(withAllowedCharacters: unreserved) ?? v }
        let query = p.map { enc($0.key) + "=" + enc($0.value) }.joined(separator: "&")
        var req: URLRequest
        if post {
            req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(query.utf8)
        } else {
            req = URLRequest(url: URL(string: endpoint.absoluteString + "?" + query)!)
        }
        let (data, _) = try await session.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMError.api("bad response")
        }
        if let code = json["error"] as? Int {
            throw LastFMError.code(code, json["message"] as? String ?? "")
        }
        return json
    }
}

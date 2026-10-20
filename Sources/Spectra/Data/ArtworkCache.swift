import Foundation
import CryptoKit

/// On-disk cache for cover art. Two sources, in order of preference:
/// 1. artwork embedded in the audio file (extracted at scan time), and
/// 2. a square cover fetched from the **iTunes Search API** (no API key needed)
///    when a file carries none.
/// Everything is cached under Caches/Spectra/Artwork keyed by a content hash, so
/// a given album/track is only fetched once.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let dir: URL
    private var remoteMemo: [String: URL?] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        dir = caches.appendingPathComponent("Spectra/Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ key: String) -> URL {
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(h).jpg")
    }

    /// Persist artwork bytes embedded in a file; returns the cached file path.
    func storeEmbedded(_ data: Data, key: String) -> String? {
        guard !data.isEmpty else { return nil }
        let f = file(key)
        if !FileManager.default.fileExists(atPath: f.path) {
            guard (try? data.write(to: f)) != nil else { return nil }
        }
        return f.path
    }

    /// A square cover for (artist, title) via iTunes, downloaded and cached.
    /// `isAlbum` picks the album vs. song entity. Returns a local file URL.
    func remoteCover(artist: String, title: String, isAlbum: Bool) async -> URL? {
        let key = "itunes|\(isAlbum ? "a" : "s")|\(artist.lowercased())|\(title.lowercased())"
        if let cached = remoteMemo[key] { return cached }
        let f = file(key)
        if FileManager.default.fileExists(atPath: f.path) { remoteMemo[key] = f; return f }

        guard let remote = await Self.iTunesArtworkURL(artist: artist, title: title, isAlbum: isAlbum) else {
            remoteMemo[key] = URL?.none
            return nil
        }
        if let (data, _) = try? await URLSession.shared.data(from: remote), !data.isEmpty {
            try? data.write(to: f)
            remoteMemo[key] = f
            return f
        }
        remoteMemo[key] = remote
        return remote
    }

    private static func iTunesArtworkURL(artist: String, title: String, isAlbum: Bool) async -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: isAlbum ? "album" : "song"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        struct Resp: Decodable { let results: [Item]; struct Item: Decodable { let artworkUrl100: String? } }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data),
              let art = decoded.results.first?.artworkUrl100 else { return nil }
        // iTunes returns a 100×100 thumb; request a 600×600 by rewriting the size.
        let big = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: big)
    }
}

import Foundation

/// « Radio ♥ » — loving a track grows a Spectra-local playlist:
/// 1. Last.fm `track.getSimilar` gives ~50 candidates (free);
/// 2. a small LOCAL model behind LiteLLM (`cheap-model-ollama`, $0) drops
///    duplicates / remixes / live takes and orders the flow — if it fails or
///    answers badly, the raw Last.fm order is used instead;
/// 3. each pick is found in the user's sources (Local > Plex > YouTube Music);
/// 4. found tracks are appended, deduplicated, to the « Radio ♥ » playlist.
///
/// The LiteLLM key is a virtual key allowed on that one alias, with a $1/30 d
/// circuit breaker (`00-infra/scripts/litellm-cle-spectra.sh`). It arrives via
/// a one-shot provisioning file, imported into the Keychain then deleted.
@MainActor
final class RadioBuilder: ObservableObject {
    static let shared = RadioBuilder()
    static let playlistName = "Radio ♥"

    @Published private(set) var status: String?
    weak var model: AppModel?

    private let endpoint = URL(string: "https://litellm.savethemall.eu/v1/chat/completions")!
    private let alias = "cheap-model-ollama"
    private let keyAccount = "litellm.key"
    private let maxPicks = 12

    func start() { importProvisioningFile() }

    /// `Application Support/Spectra/litellm-provision.json` = {"key": "sk-…"}.
    private func importProvisioningFile() {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectra/litellm-provision.json")
        guard let data = try? Data(contentsOf: file) else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let key = obj["key"], key.hasPrefix("sk-") {
            Keychain.set(key, account: keyAccount)
        }
    }

    // MARK: entry point

    func grow(from seed: PlexMetadata) {
        Task { await build(seed: seed) }
    }

    private func build(seed: PlexMetadata) async {
        let artist = seed.grandparentTitle ?? ""
        guard !artist.isEmpty else { show("Radio ♥: no artist on “\(seed.title)”."); return }
        show("Radio ♥: finding tracks like “\(seed.title)”…", sticky: true)

        let candidates = await LastFM.shared.similarTracks(artist: artist, title: seed.title, limit: 50)
        guard !candidates.isEmpty else { show("Radio ♥: Last.fm knows nothing similar to “\(seed.title)”."); return }

        show("Radio ♥: picking the best of \(candidates.count)…", sticky: true)
        let order = await llmPicks(seed: "\(artist) — \(seed.title)", candidates: candidates)
            ?? Array(candidates.indices.prefix(maxPicks))
        let picks = order.filter { candidates.indices.contains($0) }.prefix(maxPicks).map { candidates[$0] }

        show("Radio ♥: finding \(picks.count) tracks in your sources…", sticky: true)
        guard let model else { return }
        var found: [Int: PlexMetadata] = [:]
        await withTaskGroup(of: (Int, PlexMetadata?).self) { group in
            for (i, p) in picks.enumerated() {
                group.addTask { (i, await model.findSong(artist: p.artist, title: p.title)) }
            }
            for await (i, m) in group { if let m { found[i] = m } }
        }
        let tracks = found.keys.sorted().compactMap { found[$0] }
        guard let id = AppDatabase.shared.playlistID(named: Self.playlistName, kind: "radio") else { return }
        let added = AppDatabase.shared.append(tracks, toPlaylist: id)
        model.reloadLocalPlaylists()
        show("Radio ♥: +\(added) track(s) from “\(seed.title)”" + (tracks.count < picks.count ? " (\(picks.count - tracks.count) not found)" : ""))
    }

    private func show(_ s: String, sticky: Bool = false) {
        status = s
        guard !sticky else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            if status == s { status = nil }
        }
    }

    // MARK: LLM curation

    /// Indices into `candidates`, best flow first; nil on any failure.
    private func llmPicks(seed: String, candidates: [LastFM.Similar]) async -> [Int]? {
        guard let key = Keychain.get(account: keyAccount) else { return nil }
        let list = candidates.enumerated().map { "\($0.offset). \($0.element.artist) — \($0.element.title)" }
            .joined(separator: "\n")
        let likes = AppDatabase.shared.recentLikes(limit: 10).joined(separator: "\n")
        let system = """
            You curate a personal radio playlist. Reply ONLY with JSON {"picks":[indices],"reason":"..."}. \
            Pick at most \(maxPicks) candidates, ordered so they flow well after the seed. \
            Exclude remixes, live versions, karaoke, instrumentals, sped-up/slowed versions, \
            and several versions of the same song. Prefer variety of artists.
            """
        let user = "Seed: \(seed)\n\nRecently loved:\n\(likes.isEmpty ? "(none)" : likes)\n\nCandidates:\n\(list)"
        let body: [String: Any] = [
            "model": alias, "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        var req = URLRequest(url: endpoint, timeoutInterval: 150)   // cold model load measured at 43 s
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        else { return nil }
        return Self.parsePicks(content, count: candidates.count)
    }

    /// Tolerant parse: the JSON object may be wrapped in prose or a code fence.
    static func parsePicks(_ content: String, count: Int) -> [Int]? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(content[start...end].utf8)) as? [String: Any],
              let raw = obj["picks"] as? [Any] else { return nil }
        var seen = Set<Int>()
        let picks = raw.compactMap { ($0 as? Int) ?? Int("\($0)") }.filter { (0..<count).contains($0) && seen.insert($0).inserted }
        return picks.isEmpty ? nil : picks
    }
}

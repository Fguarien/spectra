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
    static let playlistPrefix = "Radio ♥ — "
    static let lengths = [10, 30, 50]

    /// Tracks per radio (seed included): 10, 30 or 50 — Settings → Radio ♥.
    @Published var length: Int = {
        let v = UserDefaults.standard.integer(forKey: "radio.length")
        return RadioBuilder.lengths.contains(v) ? v : 30
    }() {
        didSet { UserDefaults.standard.set(length, forKey: "radio.length") }
    }

    @Published private(set) var status: String?
    weak var model: AppModel?

    private let endpoint = URL(string: "https://litellm.savethemall.eu/v1/chat/completions")!
    private let alias = "cheap-model-ollama"
    private let keyAccount = "litellm.key"

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

        let target = length
        let maxPicks = target - 1                       // the seed opens the radio
        // Enough candidates for the LLM to choose from and for misses to resolve.
        let candidates = await LastFM.shared.similarTracks(artist: artist, title: seed.title,
                                                           limit: min(100, max(50, target * 2)))
        guard !candidates.isEmpty else { show("Radio ♥: Last.fm knows nothing similar to “\(seed.title)”."); return }

        show("Radio ♥: picking the best of \(candidates.count)…", sticky: true)
        // Ask for a few extra: some picks won't be found in any source.
        let wanted = min(candidates.count, maxPicks + max(3, maxPicks / 5))
        let order = await llmPicks(seed: "\(artist) — \(seed.title)", candidates: candidates, count: wanted)
            ?? Array(candidates.indices.prefix(wanted))
        let picks = order.filter { candidates.indices.contains($0) }.prefix(wanted).map { candidates[$0] }

        show("Radio ♥: finding \(picks.count) tracks in your sources…", sticky: true)
        guard let model else { return }
        // At most 4 lookups at once: each may spawn a yt-dlp/ytmusicapi process.
        var found: [Int: PlexMetadata] = [:]
        await withTaskGroup(of: (Int, PlexMetadata?).self) { group in
            var next = 0
            func launch() {
                guard next < picks.count else { return }
                let i = next, p = picks[i]; next += 1
                group.addTask { (i, await model.findSong(artist: p.artist, title: p.title)) }
            }
            for _ in 0..<4 { launch() }
            for await (i, m) in group {
                if let m { found[i] = m }
                launch()
            }
        }
        let tracks = [seed] + found.keys.sorted().compactMap { found[$0] }.prefix(maxPicks)
        let name = Self.playlistPrefix + seed.title
        guard let id = AppDatabase.shared.playlistID(named: name, kind: "radio") else { return }
        let added = AppDatabase.shared.append(Array(tracks), toPlaylist: id)
        model.reloadLocalPlaylists()
        show("“\(name)”: \(added) track(s)" + (tracks.count < target ? " — only \(tracks.count) of \(target) found" : ""))
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
    private func llmPicks(seed: String, candidates: [LastFM.Similar], count maxPicks: Int) async -> [Int]? {
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
        var req = URLRequest(url: endpoint, timeoutInterval: 240)   // measured: 43 s cold (12 picks), 91 s for a 50-track radio
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

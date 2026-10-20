import Foundation
import GRDB

// MARK: - models

/// One track of the merged library, flattened for tables and grids. `meta` is
/// the provider's own row (tagged with its account), used to play, love,
/// download and rate exactly as everywhere else in the app.
struct CatalogTrack: Identifiable, Hashable {
    let accountID: String
    let ratingKey: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String      // primary artist, used for grouping
    let trackNo: Int?
    let disc: Int?
    let durationMs: Int
    let year: Int?
    let genre: String?
    let addedAt: Date
    let meta: PlexMetadata

    var id: String { "\(accountID)|\(ratingKey)" }
    static func == (l: CatalogTrack, r: CatalogTrack) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var albumKey: String { CatalogStore.key(albumArtist, album) }
    var thumb: String? { meta.thumb ?? meta.parentThumb }

    // Sort keys for `Table` (KeyPathComparator needs Comparable values).
    var sortTrackNo: Int { (disc ?? 1) * 1000 + (trackNo ?? 0) }
    var sortYear: Int { year ?? 0 }
    var sortGenre: String { genre ?? "" }
}

/// An album as Music.app shows it: the same album found in several sources is
/// one album; each song appears once, served by the best source
/// (Local > Plex > YouTube Music).
struct CatalogAlbum: Identifiable, Hashable {
    let id: String               // normalised "artist|album"
    let title: String
    let artist: String
    let year: Int?
    let genre: String?
    let addedAt: Date
    let tracks: [CatalogTrack]
    let accountIDs: [String]

    static func == (l: CatalogAlbum, r: CatalogAlbum) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Track that provides the cover (first one with artwork).
    var coverTrack: CatalogTrack? { tracks.first { $0.thumb != nil } ?? tracks.first }
    var durationMs: Int { tracks.reduce(0) { $0 + $1.durationMs } }
}

struct CatalogArtist: Identifiable, Hashable {
    let id: String
    let name: String
    let albums: [CatalogAlbum]
    static func == (l: CatalogArtist, r: CatalogArtist) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct CatalogGenre: Identifiable, Hashable {
    let id: String
    let name: String
    let albums: [CatalogAlbum]
    static func == (l: CatalogGenre, r: CatalogGenre) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - store

/// The merged library. Loaded from SQLite at launch (instant, offline-safe),
/// then each account is re-listed in the background when its copy is older
/// than an hour. Grouping into albums / artists / genres runs off the main
/// thread.
@MainActor
final class CatalogStore: ObservableObject {
    static let shared = CatalogStore()

    @Published private(set) var tracks: [CatalogTrack] = []
    @Published private(set) var albums: [CatalogAlbum] = []        // by title
    @Published private(set) var artists: [CatalogArtist] = []      // by name
    @Published private(set) var genres: [CatalogGenre] = []
    @Published private(set) var syncing: Set<String> = []          // account IDs
    @Published private(set) var errors: [String: String] = [:]
    /// Normalised search text, parallel to `tracks` / `albums` (built once,
    /// not per keystroke: folding 27 000 titles each time made search lag).
    private var trackKeys: [String] = []
    private var albumKeys: [String] = []
    /// One library on its own (sidebar « Library » rows), built on demand
    /// from that account's rows only — the merged lists keep one copy per
    /// song, so filtering them would hide what a source also has elsewhere.
    private var perSource: [String: Built] = [:]
    @Published private(set) var version = 0

    /// accountID → kind, for source ranking and badges (set by AppModel).
    var kinds: [String: ProviderKind] = [:]
    private var running: Set<String> = []

    static let maxAge: TimeInterval = 3600

    // MARK: keys

    nonisolated static func key(_ artist: String, _ album: String) -> String {
        MergedArtist.normalise(artist) + "|" + MergedArtist.normalise(album)
    }

    /// "Ninho, Jul" / "Ninho & Jul" / "Ninho feat. Jul" → "Ninho".
    nonisolated static func primaryArtist(_ s: String) -> String {
        var a = s
        for sep in [", ", " & ", " feat. ", " feat ", " ft. ", " x ", " / "] {
            if let r = a.range(of: sep, options: .caseInsensitive) { a = String(a[..<r.lowerBound]) }
        }
        let t = a.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? s : t
    }

    // MARK: load

    func load(accounts: [Account]) {
        kinds = Dictionary(accounts.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let valid = Set(accounts.map(\.id))
        let kinds = self.kinds
        Task {
            let built = await Task.detached(priority: .userInitiated) {
                let rows = AppDatabase.shared.catalogRows().filter { valid.contains($0.accountID) }
                return Self.build(rows, kinds: kinds)
            }.value
            apply(built)
        }
    }

    private func apply(_ b: Built) {
        tracks = b.tracks; albums = b.albums; artists = b.artists; genres = b.genres
        trackKeys = b.trackKeys; albumKeys = b.albumKeys
        perSource = [:]; version += 1
    }

    func library(for accountID: String) async -> Built {
        if let b = perSource[accountID] { return b }
        let kinds = self.kinds
        let b = await Task.detached(priority: .userInitiated) {
            Self.build(AppDatabase.shared.catalogRows().filter { $0.accountID == accountID }, kinds: kinds)
        }.value
        perSource[accountID] = b
        return b
    }

    /// Library matches for the search page: albums by title or artist, songs
    /// by title or artist.
    func search(_ query: String, albumLimit: Int = 20, songLimit: Int = 40) -> ([CatalogAlbum], [CatalogTrack]) {
        let n = MergedArtist.normalise(query)
        guard n.count >= 2 else { return ([], []) }
        var al: [CatalogAlbum] = [], so: [CatalogTrack] = []
        for (i, k) in albumKeys.enumerated() where k.contains(n) {
            al.append(albums[i]); if al.count == albumLimit { break }
        }
        for (i, k) in trackKeys.enumerated() where k.contains(n) {
            so.append(tracks[i]); if so.count == songLimit { break }
        }
        return (al, so)
    }

    // MARK: refresh

    func refreshIfStale(accountID: String, provider: any MusicProvider) {
        let synced = AppDatabase.shared.catalogSyncedAt(accountID)
        guard synced.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true else { return }
        refresh(accountID: accountID, provider: provider)
    }

    func refresh(accountID: String, provider: any MusicProvider) {
        guard !running.contains(accountID) else { return }
        running.insert(accountID); syncing.insert(accountID)
        Task {
            defer { running.remove(accountID); syncing.remove(accountID) }
            do {
                let rows = try await provider.catalog().map { $0.tagged(accountID) }
                // An empty answer from a source that had songs is a failure
                // (bridge down, server unreachable), not « you deleted it all ».
                if rows.isEmpty, AppDatabase.shared.catalogCount(accountID) > 0 { return }
                await Task.detached(priority: .utility) {
                    AppDatabase.shared.replaceCatalog(accountID: accountID, rows: rows)
                }.value
                errors[accountID] = nil
                let valid = Set(kinds.keys), kinds = self.kinds
                let built = await Task.detached(priority: .userInitiated) {
                    Self.build(AppDatabase.shared.catalogRows().filter { valid.contains($0.accountID) }, kinds: kinds)
                }.value
                apply(built)
            } catch {
                errors[accountID] = error.localizedDescription
            }
        }
    }

    func forget(accountID: String) {
        AppDatabase.shared.deleteCatalog(accountID)
        kinds[accountID] = nil
        let valid = Set(kinds.keys), kinds = self.kinds
        Task {
            let built = await Task.detached {
                Self.build(AppDatabase.shared.catalogRows().filter { valid.contains($0.accountID) }, kinds: kinds)
            }.value
            apply(built)
        }
    }

    // MARK: grouping (off main)

    struct Built: Sendable {
        var tracks: [CatalogTrack] = []
        var albums: [CatalogAlbum] = []
        var artists: [CatalogArtist] = []
        var genres: [CatalogGenre] = []
        var trackKeys: [String] = []
        var albumKeys: [String] = []
    }

    nonisolated static func rank(_ kind: ProviderKind?) -> Int {
        switch kind {
        case .local: return 0
        case .plex: return 1
        case .youtubeMusic: return 2
        case nil: return 3
        }
    }

    nonisolated static func build(_ rows: [CatalogTrack], kinds: [String: ProviderKind]) -> Built {
        var b = Built()
        // Albums: group, then keep one copy of each song (best source first).
        var groups: [String: [CatalogTrack]] = [:]
        for t in rows { groups[t.albumKey, default: []].append(t) }
        var albums: [CatalogAlbum] = []
        for (key, list) in groups {
            let ranked = list.sorted { rank(kinds[$0.accountID]) < rank(kinds[$1.accountID]) }
            var seen = Set<String>()
            var songs: [CatalogTrack] = []
            for t in ranked where seen.insert("\(t.disc ?? 1)|" + MergedArtist.normalise(t.title)).inserted {
                songs.append(t)
            }
            songs.sort { ($0.sortTrackNo, $0.addedAt) < ($1.sortTrackNo, $1.addedAt) }
            // A YouTube album lists no numbers: keep the library order there.
            if songs.allSatisfy({ $0.trackNo == nil }) { songs.sort { $0.addedAt > $1.addedAt } }
            let lead = ranked[0]
            var accounts: [String] = []
            for t in ranked where !accounts.contains(t.accountID) { accounts.append(t.accountID) }
            albums.append(CatalogAlbum(
                id: key, title: lead.album, artist: lead.albumArtist,
                year: ranked.compactMap(\.year).first, genre: ranked.compactMap(\.genre).first,
                addedAt: list.map(\.addedAt).max() ?? .distantPast, tracks: songs, accountIDs: accounts))
        }
        albums.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        b.albums = albums
        b.tracks = albums.flatMap(\.tracks)
        b.albumKeys = albums.map { MergedArtist.normalise($0.title + " " + $0.artist) }
        b.trackKeys = b.tracks.map { MergedArtist.normalise($0.title + " " + $0.artist) }

        var byArtist: [String: [CatalogAlbum]] = [:]
        var artistName: [String: String] = [:]
        for a in albums {
            let k = MergedArtist.normalise(a.artist)
            byArtist[k, default: []].append(a)
            if artistName[k] == nil { artistName[k] = a.artist }
        }
        b.artists = byArtist.map { k, list in
            CatalogArtist(id: k, name: artistName[k] ?? k,
                          albums: list.sorted { ($0.year ?? 9999, $0.title) < ($1.year ?? 9999, $1.title) })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var byGenre: [String: [CatalogAlbum]] = [:]
        var genreName: [String: String] = [:]
        for a in albums {
            guard let g = a.genre, !g.isEmpty else { continue }
            let k = MergedArtist.normalise(g)
            byGenre[k, default: []].append(a)
            if genreName[k] == nil { genreName[k] = g }
        }
        b.genres = byGenre.map { CatalogGenre(id: $0.key, name: genreName[$0.key] ?? $0.key, albums: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return b
    }
}

// MARK: - persistence

extension AppDatabase {
    func catalogRows() -> [CatalogTrack] {
        let rows = (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT accountID, ratingKey, title, artist, album, trackNo, disc, durationMs, year, genre, addedAt, meta FROM catalogTrack")
        }) ?? []
        let dec = JSONDecoder()
        return rows.compactMap { r in
            let acc: String = r["accountID"], key: String = r["ratingKey"]
            guard let json: String = r["meta"],
                  let meta = try? dec.decode(PlexMetadata.self, from: Data(json.utf8)) else { return nil }
            let artist: String = r["artist"] ?? ""
            let albumRaw: String = r["album"] ?? ""
            return CatalogTrack(
                accountID: acc, ratingKey: key, title: r["title"],
                artist: artist.isEmpty ? "Unknown Artist" : artist,
                album: albumRaw.isEmpty ? "Singles" : albumRaw,
                albumArtist: artist.isEmpty ? "Unknown Artist" : CatalogStore.primaryArtist(artist),
                trackNo: r["trackNo"], disc: r["disc"], durationMs: r["durationMs"],
                year: r["year"], genre: r["genre"],
                addedAt: (r["addedAt"] as Double?).map { Date(timeIntervalSince1970: $0) } ?? .distantPast,
                meta: meta.tagged(acc))
        }
    }

    func catalogSyncedAt(_ accountID: String) -> Date? {
        (try? dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT syncedAt FROM catalogSync WHERE accountID = ?", arguments: [accountID])
        }).map { Date(timeIntervalSince1970: $0) }
    }

    func catalogCount(_ accountID: String) -> Int {
        (try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catalogTrack WHERE accountID = ?", arguments: [accountID])
        } ?? 0) ?? 0
    }

    /// Replace one account's rows. `addedAt` survives a refresh when the
    /// source gives none (YouTube Music): it stays the date first seen, and a
    /// first sync spreads it one second apart to keep the library's order.
    func replaceCatalog(accountID: String, rows: [PlexMetadata]) {
        let enc = JSONEncoder()
        let now = Date().timeIntervalSince1970
        try? dbQueue.write { db in
            try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS keep (k TEXT PRIMARY KEY)")
            try db.execute(sql: "DELETE FROM keep")
            for (i, m) in rows.enumerated() where m.type == nil || m.type == "track" {
                guard let json = try? String(data: enc.encode(m), encoding: .utf8) else { continue }
                let given = m.addedAt.map(Double.init)
                try db.execute(sql: """
                    INSERT INTO catalogTrack (accountID, ratingKey, title, artist, album, trackNo, disc, durationMs, year, genre, addedAt, meta)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, ?), ?)
                    ON CONFLICT(accountID, ratingKey) DO UPDATE SET
                      title = excluded.title, artist = excluded.artist, album = excluded.album,
                      trackNo = excluded.trackNo, disc = excluded.disc, durationMs = excluded.durationMs,
                      year = excluded.year, genre = excluded.genre, meta = excluded.meta,
                      addedAt = COALESCE(?, catalogTrack.addedAt)
                    """, arguments: [accountID, m.ratingKey, m.title, m.grandparentTitle, m.parentTitle,
                                     m.index, m.parentIndex, m.duration ?? 0, m.parentYear ?? m.year,
                                     m.Genre?.first?.tag, given, now - Double(i), json, given])
                try db.execute(sql: "INSERT OR IGNORE INTO keep VALUES (?)", arguments: [m.ratingKey])
            }
            try db.execute(sql: "DELETE FROM catalogTrack WHERE accountID = ? AND ratingKey NOT IN (SELECT k FROM keep)",
                           arguments: [accountID])
            try db.execute(sql: "INSERT OR REPLACE INTO catalogSync (accountID, syncedAt, count) VALUES (?, ?, ?)",
                           arguments: [accountID, now, rows.count])
        }
    }

    func deleteCatalog(_ accountID: String) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM catalogTrack WHERE accountID = ?", arguments: [accountID])
            try db.execute(sql: "DELETE FROM catalogSync WHERE accountID = ?", arguments: [accountID])
        }
    }
}

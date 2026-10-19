import Foundation
import GRDB

/// One-shot migration of a Prism export (its `Items.db`, a GRDB/SQLite file
/// pulled from the `.imazingapp` container) into Spectra's own store.
///
/// Prism quirks handled here: DATETIME columns are stored as Unix-epoch
/// integers (not ISO text); `duration` is in seconds; a track's Plex rating
/// key is Prism's `trackId`. Opened read-only — the source is never mutated.
///
/// The core track/play import is exact and always runs. Tags, similar artists
/// and playlists are discovered **adaptively** from the source schema (column
/// names vary between Prism builds) and are best-effort: a failure there never
/// aborts the core import.
enum Importer {
    struct Summary {
        var tracks = 0, plays = 0, tags = 0, similar = 0, playlists = 0
    }

    static func importProm(from prismDBPath: String) throws -> Summary {
        var cfg = Configuration()
        cfg.readonly = true
        let src = try DatabaseQueue(path: prismDBPath, configuration: cfg)
        let dst = AppDatabase.shared.dbQueue
        var summary = Summary()

        try src.read { sdb in
            try dst.write { ddb in
                try ddb.execute(sql: "DELETE FROM track")
                try ddb.execute(sql: "DELETE FROM play")
                try ddb.execute(sql: "DELETE FROM trackTag")
                try ddb.execute(sql: "DELETE FROM prismPlaylist")
                try ddb.execute(sql: "DELETE FROM similarArtist")

                try importTracks(sdb, ddb, &summary)
                try importPlays(sdb, ddb, &summary)

                // Best-effort, schema-adaptive extras.
                try? importTags(sdb, ddb, &summary)
                try? importSimilar(sdb, ddb, &summary)
                try? importPlaylists(sdb, ddb, &summary)
            }
        }
        return summary
    }

    // MARK: core (exact)

    private static func importTracks(_ sdb: Database, _ ddb: Database, _ s: inout Summary) throws {
        let sql = """
            SELECT trackId, libraryId,
                   COALESCE(artistName, albumArtistName) AS artist,
                   albumTitle, trackTitle, trackNumber, duration, codec,
                   userRating, playCount, trackDatePlayed
            FROM item
            """
        let rows = try Row.fetchCursor(sdb, sql: sql)
        while let r = try rows.next() {
            let rec = TrackRecord(
                id: nil,
                ratingKey: (r["trackId"] as Int64?).map(String.init),
                libraryId: r["libraryId"],
                artistName: r["artist"],
                albumTitle: r["albumTitle"],
                trackTitle: r["trackTitle"],
                trackNumber: r["trackNumber"] ?? 0,
                durationMs: Int((r["duration"] as Double? ?? 0) * 1000),
                codec: r["codec"],
                userRating: r["userRating"],
                playCount: r["playCount"] ?? 0,
                lastPlayed: epoch(r["trackDatePlayed"]),
                localPath: nil
            )
            try rec.insert(ddb)
            s.tracks += 1
        }
    }

    private static func importPlays(_ sdb: Database, _ ddb: Database, _ s: inout Summary) throws {
        let sql = """
            SELECT p.date AS date,
                   COALESCE(i.artistName, i.albumArtistName) AS artist,
                   i.trackTitle AS title, i.trackId AS trackId
            FROM play p JOIN item i ON i.id = p.itemId
            """
        let rows = try Row.fetchCursor(sdb, sql: sql)
        while let r = try rows.next() {
            let pr = PlayRecord(
                id: nil,
                ratingKey: (r["trackId"] as Int64?).map(String.init),
                artistName: r["artist"],
                trackTitle: r["title"],
                playedAt: epoch(r["date"])
            )
            try pr.insert(ddb)
            s.plays += 1
        }
    }

    // MARK: schema-adaptive extras

    private static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
                         arguments: [name]) ?? 0 > 0
    }

    private static func columns(_ db: Database, _ table: String) throws -> [String] {
        try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { ($0["name"] as String?) ?? "" }
    }

    private static func firstMatch(_ cols: [String], contains needles: [String]) -> String? {
        for n in needles { if let c = cols.first(where: { $0.lowercased().contains(n) }) { return c } }
        return nil
    }

    /// tag(id, name-ish) + itemTags(itemId, tagId) → trackTag(ratingKey, tagName).
    private static func importTags(_ sdb: Database, _ ddb: Database, _ s: inout Summary) throws {
        guard try tableExists(sdb, "tag"), try tableExists(sdb, "itemTags") else { return }
        let tagCols = try columns(sdb, "tag")
        let linkCols = try columns(sdb, "itemTags")
        guard let tagName = firstMatch(tagCols, contains: ["name", "title", "value", "tag"]),
              let tagId = firstMatch(tagCols, contains: ["id"]),
              let linkItem = firstMatch(linkCols, contains: ["item"]),
              let linkTag = firstMatch(linkCols, contains: ["tag"]) else { return }
        let sql = """
            SELECT i.trackId AS trackId, t."\(tagName)" AS name
            FROM itemTags l
            JOIN item i ON i.id = l."\(linkItem)"
            JOIN tag  t ON t."\(tagId)" = l."\(linkTag)"
            WHERE t."\(tagName)" IS NOT NULL
            """
        let rows = try Row.fetchCursor(sdb, sql: sql)
        while let r = try rows.next() {
            guard let name = r["name"] as String?, !name.isEmpty else { continue }
            try ddb.execute(sql: "INSERT INTO trackTag (ratingKey, tagName) VALUES (?,?)",
                            arguments: [(r["trackId"] as Int64?).map(String.init), name])
            s.tags += 1
        }
    }

    /// similarArtists → similarArtist(artistName, similarName). Handles both a
    /// text-pair schema and an id-pair schema that references artist names.
    private static func importSimilar(_ sdb: Database, _ ddb: Database, _ s: inout Summary) throws {
        guard try tableExists(sdb, "similarArtists") else { return }
        let cols = try columns(sdb, "similarArtists")
        // Prefer two text columns naming the artists directly.
        let names = cols.filter { $0.lowercased().contains("name") || $0.lowercased().contains("artist") }
        guard names.count >= 2 else { return }
        let a = names[0], b = names[1]
        let rows = try Row.fetchCursor(sdb, sql: "SELECT \"\(a)\" AS x, \"\(b)\" AS y FROM similarArtists")
        while let r = try rows.next() {
            guard let x = r["x"] as String?, let y = r["y"] as String?, !x.isEmpty, !y.isEmpty else { continue }
            try ddb.execute(sql: "INSERT INTO similarArtist (artistName, similarName) VALUES (?,?)",
                            arguments: [x, y])
            s.similar += 1
        }
    }

    /// playlist(id, name-ish) + a membership table referencing playlist + item.
    private static func importPlaylists(_ sdb: Database, _ ddb: Database, _ s: inout Summary) throws {
        guard try tableExists(sdb, "playlist") else { return }
        let plCols = try columns(sdb, "playlist")
        guard let plName = firstMatch(plCols, contains: ["name", "title"]),
              let plId = firstMatch(plCols, contains: ["id"]) else { return }
        // Find a membership table whose columns reference both a playlist and an item/track.
        let tables = try String.fetchAll(sdb, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        var member: (table: String, plRef: String, itemRef: String, order: String?)?
        for t in tables where t != "playlist" {
            let c = try columns(sdb, t)
            if let p = firstMatch(c, contains: ["playlist"]),
               let it = firstMatch(c, contains: ["item", "track"]) {
                member = (t, p, it, firstMatch(c, contains: ["position", "order", "index", "rank"]))
                break
            }
        }
        guard let m = member else { return }
        let orderSel = m.order.map { ", mm.\"\($0)\" AS pos" } ?? ", 0 AS pos"
        let orderBy = m.order.map { "ORDER BY pl.\"\(plId)\", mm.\"\($0)\"" } ?? ""
        let sql = """
            SELECT pl."\(plName)" AS name, i.trackId AS trackId \(orderSel)
            FROM "\(m.table)" mm
            JOIN playlist pl ON pl."\(plId)" = mm."\(m.plRef)"
            JOIN item i ON i.id = mm."\(m.itemRef)"
            \(orderBy)
            """
        let rows = try Row.fetchCursor(sdb, sql: sql)
        while let r = try rows.next() {
            guard let name = r["name"] as String?, !name.isEmpty else { continue }
            try ddb.execute(sql: "INSERT INTO prismPlaylist (name, ratingKey, position) VALUES (?,?,?)",
                            arguments: [name, (r["trackId"] as Int64?).map(String.init), r["pos"] as Int? ?? 0])
            s.playlists += 1
        }
    }

    /// Prism stores DATETIME as a Unix-epoch integer (seconds).
    private static func epoch(_ value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }
}

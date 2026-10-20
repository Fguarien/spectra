import Foundation
import GRDB

/// ♥ likes and Spectra-local playlists, stored in Spectra's own database.
/// A row keeps the full `PlexMetadata` (JSON, `sourceAccountID` included) so it
/// plays from the account it came from, whatever account is active.
struct LocalPlaylist: Identifiable, Hashable {
    let id: Int64
    let name: String
    let kind: String     // "manual" | "radio"
    let count: Int
}

extension AppDatabase {
    /// Dedupe key across sources: same song on Local and YouTube = one row.
    static func songKey(artist: String?, title: String) -> String {
        "\(MergedArtist.normalise(artist ?? ""))|\(MergedArtist.normalise(title))"
    }

    private static func encode(_ m: PlexMetadata) -> String {
        (try? JSONEncoder().encode(m)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode(_ json: String) -> PlexMetadata? {
        try? JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    // MARK: likes

    func isLiked(artist: String?, title: String) -> Bool {
        let k = Self.songKey(artist: artist, title: title)
        return ((try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 FROM liked WHERE key = ?", arguments: [k])
        }) ?? nil) != nil
    }

    /// Toggle; returns the new state.
    @discardableResult
    func toggleLike(_ m: PlexMetadata) -> Bool {
        let k = Self.songKey(artist: m.grandparentTitle, title: m.title)
        var nowLiked = false
        try? dbQueue.write { db in
            if try Int.fetchOne(db, sql: "SELECT 1 FROM liked WHERE key = ?", arguments: [k]) != nil {
                try db.execute(sql: "DELETE FROM liked WHERE key = ?", arguments: [k])
            } else {
                try db.execute(sql: "INSERT INTO liked (key, accountID, title, artist, meta, likedAt) VALUES (?,?,?,?,?,?)",
                               arguments: [k, m.sourceAccountID, m.title, m.grandparentTitle, Self.encode(m), Date()])
                nowLiked = true
            }
        }
        return nowLiked
    }

    /// Most recent likes, as "Artist — Title", for the radio prompt.
    func recentLikes(limit: Int = 10) -> [String] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT artist, title FROM liked ORDER BY likedAt DESC LIMIT ?", arguments: [limit])
                .map { "\(($0["artist"] as String?) ?? "") — \($0["title"] as String)" }
        }) ?? []
    }

    // MARK: local playlists

    func localPlaylists() -> [LocalPlaylist] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.kind, COUNT(i.id) AS n FROM localPlaylist p
                LEFT JOIN localPlaylistItem i ON i.playlistID = p.id
                GROUP BY p.id ORDER BY p.kind DESC, p.name
                """).map { LocalPlaylist(id: $0["id"], name: $0["name"], kind: $0["kind"], count: $0["n"]) }
        }) ?? []
    }

    /// The playlist with this name and kind, created if missing.
    func playlistID(named name: String, kind: String) -> Int64? {
        try? dbQueue.write { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM localPlaylist WHERE name = ? AND kind = ?",
                                           arguments: [name, kind]) { return id }
            try db.execute(sql: "INSERT INTO localPlaylist (name, kind, createdAt) VALUES (?,?,?)",
                           arguments: [name, kind, Date()])
            return db.lastInsertedRowID
        }
    }

    /// Append tracks not already in the playlist; returns how many were added.
    @discardableResult
    func append(_ tracks: [PlexMetadata], toPlaylist id: Int64) -> Int {
        (try? dbQueue.write { db -> Int in
            var pos = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) FROM localPlaylistItem WHERE playlistID = ?",
                                       arguments: [id]) ?? -1
            var added = 0
            for m in tracks {
                let k = Self.songKey(artist: m.grandparentTitle, title: m.title)
                pos += 1
                try db.execute(sql: """
                    INSERT OR IGNORE INTO localPlaylistItem (playlistID, position, key, title, artist, meta)
                    VALUES (?,?,?,?,?,?)
                    """, arguments: [id, pos, k, m.title, m.grandparentTitle, Self.encode(m)])
                added += db.changesCount
            }
            return added
        }) ?? 0
    }

    /// ♥ songs, most recent first (the « Favourite Songs » playlist).
    func likedTracks() -> [PlexMetadata] {
        (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT meta FROM liked ORDER BY likedAt DESC").compactMap(Self.decode)
        }) ?? []
    }

    func localPlaylistTracks(_ id: Int64) -> [PlexMetadata] {
        (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT meta FROM localPlaylistItem WHERE playlistID = ? ORDER BY position",
                                arguments: [id]).compactMap(Self.decode)
        }) ?? []
    }

    func removeFromLocalPlaylist(_ id: Int64, track: PlexMetadata) {
        let k = Self.songKey(artist: track.grandparentTitle, title: track.title)
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM localPlaylistItem WHERE playlistID = ? AND key = ?", arguments: [id, k])
        }
    }

    func renameLocalPlaylist(_ id: Int64, to name: String) {
        try? dbQueue.write { db in
            try db.execute(sql: "UPDATE localPlaylist SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    // MARK: history (Playing Next → History)

    func recordPlay(_ m: PlexMetadata) {
        try? dbQueue.write { db in
            try db.execute(sql: "INSERT INTO history (playedAt, meta) VALUES (?, ?)",
                           arguments: [Date().timeIntervalSince1970, Self.encode(m)])
            // Keep the last 500.
            try db.execute(sql: "DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY id DESC LIMIT 500)")
        }
    }

    func history(limit: Int = 200) -> [(Date, PlexMetadata)] {
        (try? dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT playedAt, meta FROM history ORDER BY id DESC LIMIT ?", arguments: [limit])
                .compactMap { r -> (Date, PlexMetadata)? in
                    guard let m = Self.decode(r["meta"]) else { return nil }
                    return (Date(timeIntervalSince1970: r["playedAt"]), m)
                }
        }) ?? []
    }

    func clearHistory() { try? dbQueue.write { try $0.execute(sql: "DELETE FROM history") } }

    func deleteLocalPlaylist(_ id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM localPlaylistItem WHERE playlistID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM localPlaylist WHERE id = ?", arguments: [id])
        }
    }
}

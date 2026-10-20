import Foundation
import GRDB

/// Spectra's own on-disk store (GRDB/SQLite), living in Application Support.
/// Holds the migrated library + user data; the Plex server stays the source
/// of truth for streaming.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    static let shared: AppDatabase = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectra", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("spectra.sqlite").path
        return try! AppDatabase(path: path)
    }()

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "track") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ratingKey", .text)
                t.column("libraryId", .text)
                t.column("artistName", .text)
                t.column("albumTitle", .text)
                t.column("trackTitle", .text)
                t.column("trackNumber", .integer).notNull().defaults(to: 0)
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("codec", .text)
                t.column("userRating", .integer)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("lastPlayed", .datetime)
            }
            try db.create(table: "play") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ratingKey", .text)
                t.column("artistName", .text)
                t.column("trackTitle", .text)
                t.column("playedAt", .datetime)
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "track") { t in
                t.add(column: "localPath", .text)
            }
            try db.create(table: "trackTag") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ratingKey", .text)
                t.column("tagName", .text).notNull()
            }
            try db.create(table: "prismPlaylist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("ratingKey", .text)
                t.column("position", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "similarArtist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("artistName", .text).notNull()
                t.column("similarName", .text).notNull()
            }
            try db.create(indexOn: "trackTag", columns: ["tagName"])
            try db.create(indexOn: "track", columns: ["ratingKey"])
        }
        // v1.14: ♥ likes and Spectra-local playlists (multi-source). Rows keep
        // the full PlexMetadata as JSON so they play from their own account and
        // can be re-resolved by artist/title if that account disappears.
        m.registerMigration("v3-likes-local-playlists") { db in
            try db.create(table: "liked") { t in
                t.column("key", .text).primaryKey()          // normalised "artist|title"
                t.column("accountID", .text)
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("meta", .text).notNull()
                t.column("likedAt", .datetime).notNull()
            }
            try db.create(table: "localPlaylist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull().defaults(to: "manual")   // manual | radio
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "localPlaylistItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playlistID", .integer).notNull().references("localPlaylist", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("key", .text).notNull()
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("meta", .text).notNull()
                t.uniqueKey(["playlistID", "key"])
            }
        }
        // v2.0 — Music-style merged library: every track of every account,
        // refreshed in the background, so Albums / Songs / Artists / Genres
        // draw instantly and work while a source is offline. Part of the same
        // file, hence of the hourly NAS backup.
        m.registerMigration("v4-catalog") { db in
            try db.create(table: "catalogTrack") { t in
                t.column("accountID", .text).notNull()
                t.column("ratingKey", .text).notNull()
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("album", .text)
                t.column("trackNo", .integer)
                t.column("disc", .integer)
                t.column("durationMs", .integer).notNull().defaults(to: 0)
                t.column("year", .integer)
                t.column("genre", .text)
                t.column("addedAt", .double)
                t.column("meta", .text).notNull()
                t.primaryKey(["accountID", "ratingKey"])
            }
            try db.create(table: "catalogSync") { t in
                t.column("accountID", .text).primaryKey()
                t.column("syncedAt", .double).notNull()
                t.column("count", .integer).notNull()
            }
        }
        // v2.0.4 — Playing Next → History, replayable (full provider row kept).
        m.registerMigration("v5-history") { db in
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("playedAt", .double).notNull()
                t.column("meta", .text).notNull()
            }
        }
        return m
    }

    // MARK: reads used by the UI

    func trackCount() -> Int {
        (try? dbQueue.read { try TrackRecord.fetchCount($0) }) ?? 0
    }

    func topRated(limit: Int = 200) -> [TrackRecord] {
        (try? dbQueue.read { db in
            try TrackRecord
                .filter(sql: "userRating IS NOT NULL AND userRating > 0")
                .order(sql: "userRating DESC, playCount DESC")
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    func rating(forRatingKey key: String) -> Int? {
        try? dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT userRating FROM track WHERE ratingKey = ? LIMIT 1", arguments: [key])
        } ?? nil
    }

    /// Persist a rating locally (keyed by Plex ratingKey), upserting a stub row
    /// if the track was never imported.
    func setRating(_ stars: Int, ratingKey: String, title: String?, artist: String?) {
        try? dbQueue.write { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE ratingKey = ?", arguments: [ratingKey]) ?? 0
            if n > 0 {
                try db.execute(sql: "UPDATE track SET userRating = ? WHERE ratingKey = ?", arguments: [stars, ratingKey])
            } else {
                try db.execute(
                    sql: "INSERT INTO track (ratingKey, trackTitle, artistName, trackNumber, durationMs, playCount, userRating) VALUES (?,?,?,0,0,0,?)",
                    arguments: [ratingKey, title, artist, stars])
            }
        }
    }

    func localPath(forRatingKey key: String) -> String? {
        let p = try? dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT localPath FROM track WHERE ratingKey = ? AND localPath IS NOT NULL LIMIT 1", arguments: [key])
        }
        return (p ?? nil).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
    }

    func setLocalPath(_ path: String?, ratingKey: String, title: String?, artist: String?,
                      album: String? = nil, durationMs: Int, codec: String?) {
        try? dbQueue.write { db in
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE ratingKey = ?", arguments: [ratingKey]) ?? 0
            if n > 0 {
                try db.execute(sql: "UPDATE track SET localPath = ?, albumTitle = COALESCE(?, albumTitle) WHERE ratingKey = ?",
                               arguments: [path, album, ratingKey])
            } else {
                try db.execute(
                    sql: "INSERT INTO track (ratingKey, trackTitle, artistName, albumTitle, trackNumber, durationMs, codec, playCount, localPath) VALUES (?,?,?,?,0,?,?,0,?)",
                    arguments: [ratingKey, title, artist, album, durationMs, codec, path])
            }
        }
    }

    // MARK: backups on the NAS (the live DB stays local: SQLite over SMB corrupts)

    /// Consistent snapshot (SQLite backup API) written locally first, then
    /// copied to `Storage/Backup`. Keeps the newest `keep` copies.
    @discardableResult
    func backupToNAS(keep: Int = 48) throws -> URL? {
        guard let dir = Storage.dir("Backup") else { return nil }
        let stamp = DateFormatter.backupStamp.string(from: Date())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spectra-\(stamp).sqlite")
        try? FileManager.default.removeItem(at: tmp)
        let snapshot = try DatabaseQueue(path: tmp.path)
        try dbQueue.backup(to: snapshot)
        try snapshot.close()
        let dest = dir.appendingPathComponent("spectra-\(stamp).sqlite")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: tmp, to: dest)
        try? FileManager.default.removeItem(at: tmp)
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("spectra-") && $0.hasSuffix(".sqlite") }.sorted()
        for old in all.dropLast(keep) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        return dest
    }

    /// Replace the live database with a backup, in place (no restart needed).
    func restore(from url: URL) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spectra-restore.sqlite")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.copyItem(at: url, to: tmp)
        let source = try DatabaseQueue(path: tmp.path)
        try source.backup(to: dbQueue)
        try source.close()
        try? FileManager.default.removeItem(at: tmp)
    }

    func downloadedKeys() -> Set<String> {
        let keys = (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT ratingKey FROM track WHERE localPath IS NOT NULL AND ratingKey IS NOT NULL")
        }) ?? []
        return Set(keys)
    }

    func downloadedTracks() -> [TrackRecord] {
        (try? dbQueue.read { db in
            try TrackRecord.filter(sql: "localPath IS NOT NULL").order(sql: "artistName, albumTitle, trackNumber").fetchAll(db)
        }) ?? []
    }

    func tags() -> [String] {
        (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT tagName FROM trackTag ORDER BY tagName")
        }) ?? []
    }

    func prismPlaylistNames() -> [String] {
        (try? dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT name FROM prismPlaylist ORDER BY name")
        }) ?? []
    }
}

extension DateFormatter {
    static let backupStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
}

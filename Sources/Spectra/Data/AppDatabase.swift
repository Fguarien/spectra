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
        return m
    }

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
}

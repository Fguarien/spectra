import Foundation
import GRDB

/// One-shot migration of a Prism export (its `Items.db`, a GRDB/SQLite file
/// pulled from the `.imazingapp` container) into Spectra's own store.
///
/// Prism quirks handled here: DATETIME columns are stored as Unix-epoch
/// integers (not ISO text); `duration` is in seconds; a track's Plex rating
/// key is Prism's `trackId`. Opened read-only — the source is never mutated.
enum Importer {
    struct Summary { var tracks = 0; var plays = 0 }

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

                let itemSQL = """
                    SELECT trackId, libraryId,
                           COALESCE(artistName, albumArtistName) AS artist,
                           albumTitle, trackTitle, trackNumber, duration, codec,
                           userRating, playCount, trackDatePlayed
                    FROM item
                    """
                let rows = try Row.fetchCursor(sdb, sql: itemSQL)
                while let r = try rows.next() {
                    var rec = TrackRecord(
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
                        lastPlayed: epoch(r["trackDatePlayed"])
                    )
                    try rec.insert(ddb)
                    summary.tracks += 1
                }

                let playSQL = """
                    SELECT p.date AS date,
                           COALESCE(i.artistName, i.albumArtistName) AS artist,
                           i.trackTitle AS title, i.trackId AS trackId
                    FROM play p JOIN item i ON i.id = p.itemId
                    """
                let pRows = try Row.fetchCursor(sdb, sql: playSQL)
                while let r = try pRows.next() {
                    var pr = PlayRecord(
                        id: nil,
                        ratingKey: (r["trackId"] as Int64?).map(String.init),
                        artistName: r["artist"],
                        trackTitle: r["title"],
                        playedAt: epoch(r["date"])
                    )
                    try pr.insert(ddb)
                    summary.plays += 1
                }
            }
        }
        return summary
    }

    /// Prism stores DATETIME as a Unix-epoch integer (seconds).
    private static func epoch(_ value: Int64?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }
}

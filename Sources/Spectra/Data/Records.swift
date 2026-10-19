import Foundation
import GRDB

/// Local cache row for a track, plus the user-owned fields Spectra migrates
/// from Prism (rating, play count, play history) and later syncs with Plex.
struct TrackRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?                 // local autoincrement
    var ratingKey: String?         // Plex ratingKey when known
    var libraryId: String?
    var artistName: String?
    var albumTitle: String?
    var trackTitle: String?
    var trackNumber: Int
    var durationMs: Int
    var codec: String?
    var userRating: Int?           // 0...5
    var playCount: Int
    var lastPlayed: Date?

    static let databaseTableName = "track"
}

/// A migrated listening event (one play), kept for history/stats parity.
struct PlayRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var ratingKey: String?
    var artistName: String?
    var trackTitle: String?
    var playedAt: Date?

    static let databaseTableName = "play"
}

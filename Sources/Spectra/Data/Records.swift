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
    var localPath: String?         // non-nil once downloaded for offline playback

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

/// Track ↔ tag link imported from Prism (`tag` + `itemTags`), denormalised by
/// name so it survives even when a track has no live Plex ratingKey.
struct TrackTagRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var ratingKey: String?
    var tagName: String

    static let databaseTableName = "trackTag"
}

/// A Prism playlist and its ordered membership (imported for offline parity;
/// live Plex playlists are fetched separately).
struct PrismPlaylistRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var ratingKey: String?         // the track's Plex ratingKey
    var position: Int

    static let databaseTableName = "prismPlaylist"
}

/// Imported "similar artists" edges (Prism `similarArtists`).
struct SimilarArtistRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var artistName: String
    var similarName: String

    static let databaseTableName = "similarArtist"
}

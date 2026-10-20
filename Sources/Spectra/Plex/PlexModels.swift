import Foundation

// MARK: - plex.tv resources (server discovery)

struct PlexResource: Decodable {
    let name: String
    let clientIdentifier: String
    let provides: String
    let owned: Bool
    let accessToken: String?
    let connections: [PlexConnection]

    var isServer: Bool { provides.split(separator: ",").contains("server") }
}

struct PlexConnection: Decodable {
    let uri: String
    let address: String
    let port: Int
    let local: Bool
    let relay: Bool
}

// MARK: - server MediaContainer

struct MediaContainerResponse<T: Decodable>: Decodable {
    let MediaContainer: Container
    struct Container: Decodable {
        let Directory: [T]?
        let Metadata: [T]?
    }
    var items: [T] { MediaContainer.Metadata ?? MediaContainer.Directory ?? [] }
}

/// Envelope used by /hubs/search and /library/metadata/{id}/related: a list of
/// Hubs, each carrying its own Metadata/Directory rows.
struct HubContainerResponse: Decodable {
    let MediaContainer: Container
    struct Container: Decodable { let Hub: [Hub]? }
    struct Hub: Decodable {
        let title: String?
        let type: String?        // "track", "album", "artist", "playlist"…
        let Metadata: [PlexMetadata]?
        let Directory: [PlexMetadata]?
        var items: [PlexMetadata] { Metadata ?? Directory ?? [] }
    }
    var hubs: [Hub] { MediaContainer.Hub ?? [] }
}

struct PlexSection: Decodable {
    let key: String
    let type: String
    let title: String
}

/// One row of a /library/... listing. Fields are optional because the same
/// envelope is reused for artists (type 8), albums (9), tracks (10) and
/// playlists.
struct PlexMetadata: Decodable {
    let ratingKey: String
    let key: String?
    let title: String
    let type: String?
    let thumb: String?
    let art: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let parentRatingKey: String?
    let grandparentRatingKey: String?
    let index: Int?
    let duration: Int?          // milliseconds
    let userRating: Double?
    let year: Int?
    let leafCount: Int?         // playlist/album track count
    let Media: [PlexMedia]?

    /// First playable part key, e.g. "/library/parts/17224/.../file.flac".
    var firstPartKey: String? { Media?.first?.Part.first?.key }
    /// Container (file) codec, falling back to the audio stream codec.
    var codec: String? {
        (Media?.first?.Part.first?.container ?? Media?.first?.audioCodec)?.lowercased()
    }
    /// A Plex `uri` fragment for playlist operations: server://machine/.../ratingKey.
    var libraryKey: String { "/library/metadata/\(ratingKey)" }
}

extension PlexMetadata: Hashable, Identifiable {
    var id: String { ratingKey }
    static func == (l: PlexMetadata, r: PlexMetadata) -> Bool { l.ratingKey == r.ratingKey }
    func hash(into h: inout Hasher) { h.combine(ratingKey) }
}

struct PlexMedia: Decodable {
    let audioCodec: String?
    let Part: [PlexPart]
}

struct PlexPart: Decodable {
    let key: String
    let container: String?
}

// MARK: - synthesising rows for non-Plex providers

extension PlexMetadata {
    /// Builds a row for providers that aren't Plex (Local Files, …). The
    /// Plex-shaped model stays the app's internal interchange, so every view
    /// and the player work unchanged. `filePath` is carried in `Media.Part.key`
    /// (so `firstPartKey` resolves) and `thumb` holds an absolute image path.
    init(ratingKey: String, title: String, type: String,
         thumb: String? = nil, parentTitle: String? = nil, grandparentTitle: String? = nil,
         parentRatingKey: String? = nil, grandparentRatingKey: String? = nil,
         index: Int? = nil, duration: Int? = nil, year: Int? = nil,
         leafCount: Int? = nil, filePath: String? = nil, fileContainer: String? = nil) {
        self.ratingKey = ratingKey
        self.key = nil
        self.title = title
        self.type = type
        self.thumb = thumb
        self.art = nil
        self.parentTitle = parentTitle
        self.grandparentTitle = grandparentTitle
        self.parentRatingKey = parentRatingKey
        self.grandparentRatingKey = grandparentRatingKey
        self.index = index
        self.duration = duration
        self.userRating = nil
        self.year = year
        self.leafCount = leafCount
        self.Media = filePath.map {
            [PlexMedia(audioCodec: fileContainer, Part: [PlexPart(key: $0, container: fileContainer)])]
        }
    }
}

extension HubContainerResponse.Hub {
    /// A synthesised search hub for local/offline providers.
    init(title: String?, type: String?, items: [PlexMetadata]) {
        self.title = title
        self.type = type
        self.Metadata = items
        self.Directory = nil
    }
}

// MARK: - codec capability

/// Codecs AVFoundation decodes natively on macOS. Anything else (notably
/// Monkey's Audio `ape`, `wma`, `opus` in some containers) must be streamed
/// through Plex's universal transcoder.
enum AudioCapability {
    static let native: Set<String> = [
        "flac", "mp3", "aac", "m4a", "alac", "aiff", "aif", "wav", "mp4", "caf",
    ]
    static func canPlayNatively(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return true } // optimistic
        return native.contains(codec)
    }
}

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

struct PlexSection: Decodable {
    let key: String
    let type: String
    let title: String
}

/// One row of a /library/... listing. Fields are optional because the same
/// envelope is reused for artists (type 8), albums (9) and tracks (10).
struct PlexMetadata: Decodable {
    let ratingKey: String
    let title: String
    let type: String?
    let thumb: String?
    let parentTitle: String?
    let grandparentTitle: String?
    let index: Int?
    let duration: Int?          // milliseconds
    let userRating: Double?
    let year: Int?
    let Media: [PlexMedia]?

    /// First playable part key, e.g. "/library/parts/17224/.../file.flac".
    var firstPartKey: String? { Media?.first?.Part.first?.key }
    var codec: String? { Media?.first?.Part.first?.container ?? Media?.first?.audioCodec }
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

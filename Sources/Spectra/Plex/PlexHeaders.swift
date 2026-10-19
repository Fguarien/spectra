import Foundation

/// Stable identity Spectra presents to plex.tv and to servers. The client
/// identifier must persist across launches (it ties the auth token and the
/// "device" shown in Plex account settings), so it lives in UserDefaults.
enum PlexIdentity {
    static let product = "Spectra"
    static let version = "1.0"
    static let platform = "macOS"

    static var clientIdentifier: String {
        let key = "plex.clientIdentifier"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    static var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// Common X-Plex-* headers sent on every request.
    static func headers(token: String? = nil) -> [String: String] {
        var h = [
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Platform": platform,
            "X-Plex-Device": platform,
            "X-Plex-Device-Name": deviceName,
            "Accept": "application/json",
        ]
        if let token { h["X-Plex-Token"] = token }
        return h
    }
}

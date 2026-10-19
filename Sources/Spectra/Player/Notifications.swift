import Foundation
import UserNotifications
import AppKit

/// Posts a system notification when the playing track changes — but only while
/// Spectra is in the background, and only if the user hasn't turned it off.
/// Mirrors Prism's now-playing notification.
@MainActor
final class TrackNotifier {
    static let shared = TrackNotifier()
    private init() {}

    private var enabled: Bool {
        // Default on; the Settings toggle writes this key.
        UserDefaults.standard.object(forKey: "notifyOnTrackChange") as? Bool ?? true
    }

    func requestAuthIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    func notify(_ track: PlayableTrack) {
        guard enabled else { return }
        // Don't interrupt the user when they're already looking at the app.
        guard !NSApp.isActive else { return }
        Task { await post(track) }
    }

    private func post(_ track: PlayableTrack) async {
        let content = UNMutableNotificationContent()
        content.title = track.title
        if !track.artist.isEmpty { content.subtitle = track.artist }
        if !track.album.isEmpty { content.body = track.album }
        if let url = track.artworkURL, let file = await Self.downloadArtwork(url),
           let att = try? UNNotificationAttachment(identifier: "art", url: file) {
            content.attachments = [att]
        }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Fetch artwork to a temp file so it can be attached to the notification.
    private static func downloadArtwork(_ url: URL) async -> URL? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        return (try? data.write(to: dst)) == nil ? nil : dst
    }
}

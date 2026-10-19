import SwiftUI

/// In-app help, opened from the Help menu (⌘?). Plain, scrollable reference —
/// how to link Plex, import from Prism, rate, make playlists, search, download
/// for offline, drive the queue, and the keyboard shortcuts.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Spectra Help").font(.largeTitle).fontWeight(.bold)

                topic("Connecting to Plex",
                      "On first launch, choose Sign in. Spectra opens plex.tv with a 4-character link code; approve it and Spectra connects to your server automatically. Your token is stored in the macOS Keychain — never on disk in cleartext.")

                topic("Importing from Prism",
                      "Settings → Import from Prism Items.db. Pick the Items.db pulled from Prism’s .imazingapp container. Your ratings, play history, tags, similar-artist edges and playlists are migrated. The import is read-only on the source file and safe to run again.")

                topic("Rating tracks",
                      "Click the stars on any track row, or in the player bar for the current track. Ratings are saved locally and pushed to your Plex server (0–10 scale = stars × 2).")

                topic("Playlists",
                      "The Playlists pane lists your Plex playlists — play, delete, or add tracks. Imported Prism playlists can be recreated on the server from the Settings/Playlists actions.")

                topic("Search",
                      "The Search pane queries your whole library on the server. Track hits play on click; artist and album hits drill down (artist → albums → tracks).")

                topic("Offline downloads",
                      "Use a track’s context menu → Download. Downloaded tracks play from the local file and work with the Plex server unreachable. Manage them in the Downloads pane.")

                topic("Queue & playback",
                      "Playback is gapless. Toggle shuffle and cycle repeat (off / all / one) in the player bar. Open the queue to reorder, remove, or jump to a track. Unsupported codecs (e.g. APE) fall back to Plex’s universal transcoder automatically.")

                topic("Keyboard shortcuts",
                      "Space — play/pause · ⌘→ / ⌘← — next / previous · ⌘? — this help.")

                Divider()
                Text("Spectra is a native macOS client for Plex music, reimplemented against Plex’s public HTTP API. Original code — not derived from any proprietary binary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func topic(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

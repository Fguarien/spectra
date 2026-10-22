import SwiftUI

/// In-app help, opened from the Help menu (⌘?). Plain, scrollable reference:
/// sources, the merged and per-source libraries, views, search, playlists,
/// radio, queue, downloads and keyboard shortcuts.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Spectra Help").font(.largeTitle).fontWeight(.bold)

                topic("Sources",
                      "Spectra plays from three kinds of library, side by side: a Plex Media Server (File → Add Plex Account…, approve the link code on plex.tv), a folder of audio files on your Mac or a NAS (File → Add Local Folder…), and YouTube Music (File → Add YouTube Music, with a ytmusicapi browser.json for your own library, or none for search and play only). Tokens stay in the macOS Keychain.")

                topic("All Libraries and Library",
                      "All Libraries shows every source merged: one album, one copy per song (Local first, then Plex, then YouTube Music). The small badge at the top right of a cover tells where it comes from. Under Library, each source has its own row with only its own albums and songs; right-click a row to rename or refresh it. Spectra keeps a copy of each catalogue on disk and re-reads it every hour (⌘R to force).")

                topic("Pages and views",
                      "Recently Added, Recently Played, Artists, Albums, Songs and Genres, like Music. Albums and Artists can be viewed as a grid or as a list (toolbar buttons). The Songs list has sortable, resizable columns — right-click the header to show or hide them; Spectra remembers the layout.")

                topic("Search",
                      "Type in the field at the top of the sidebar. Results are grouped by source: the same song found in Plex, a local folder and YouTube Music shows under each one, so you choose the version to play; the picker at the top keeps a single source. Library matches appear at once, word by word (« flying to the moon » finds « Fly Me to the Moon »); each online source adds its results as it answers. Clear the field to get back to the page you were on.")

                topic("Playlists",
                      "File → New Playlist… (⌘N) creates a Spectra playlist, which may mix songs from every source. Add songs from any context menu → Add to Playlist. Rename a playlist from its right-click menu or by double-clicking its title. Plex and YouTube Music playlists are listed below yours.")

                topic("Favourite Songs and Radio ♥",
                      "⌘L or the heart loves the current song. Loving a song can build a « Radio ♥ » playlist from similar tracks found on Last.fm (Settings → Last.fm), optionally curated by a model behind any OpenAI-compatible endpoint (Settings → Radio ♥).")

                topic("Queue and history",
                      "The Playing Next panel (⌥⌘U) shows what plays next — reorder, remove or jump — and, in its History tab, the last 500 songs played. Playback is gapless; shuffle and repeat are in the Playback menu.")

                topic("Downloads",
                      "Context menu → Download, or Download Playlist. Files go to the Storage folder (Settings → Storage, ~/Music/Spectra by default). If that folder is on a NAS that is not mounted, downloads wait and resume when it comes back.")

                topic("Keyboard shortcuts",
                      "⌘P play/pause · ⌘→ / ⌘← next / previous · ⌘↑ / ⌘↓ volume · ⌘1–⌘5 pages · ⌘N new playlist · ⌘R refresh library · ⌘L love · ⇧⌘M mini player · ⌃⌘F full-screen player · ⌘, settings · ⌘? this help.")

                Divider()
                Text("Spectra is a native macOS music player for Plex, local files and YouTube Music. Original code, MIT licence.")
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

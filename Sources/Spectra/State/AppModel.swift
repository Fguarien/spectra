import Foundation
import SwiftUI
import AppKit

/// Top-level app state: authentication, the Plex client, browsing, search,
/// playlists, ratings and offline downloads. Drives which root screen is shown.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case signedOut, linking, loading, ready, error(String) }
    enum Pane: Hashable { case library, playlists, search, downloads, settings }

    @Published var phase: Phase = .signedOut
    @Published var linkCode: String?          // shown while the user approves in-browser
    @Published var serverName = ""
    @Published var pane: Pane = .library
    @Published var sections: [PlexSection] = []
    @Published var artists: [PlexMetadata] = []
    @Published var playlists: [PlexMetadata] = []
    @Published var searchHits: [HubContainerResponse.Hub] = []
    @Published var similarArtists: [PlexMetadata] = []
    @Published var importMessage: String?

    private(set) var client: PlexClient?
    private let auth = PlexAuth()
    private let tokenAccount = "plex.account.token"

    func bootstrap() {
        if let token = Keychain.get(account: tokenAccount) {
            Task { await connect(token: token) }
        } else {
            phase = .signedOut
        }
    }

    // MARK: sign-in

    func startLink() {
        phase = .linking
        Task {
            do {
                let pin = try await auth.requestPIN()
                linkCode = pin.code
                NSWorkspace.shared.open(auth.authURL(code: pin.code))
                let token = try await auth.pollForToken(pin: pin)
                Keychain.set(token, account: tokenAccount)
                await connect(token: token)
            } catch {
                phase = .error("Linking failed: \(error.localizedDescription)")
            }
        }
    }

    func signOut() {
        Keychain.delete(account: tokenAccount)
        client = nil
        sections = []; artists = []; playlists = []; searchHits = []; similarArtists = []
        serverName = ""
        phase = .signedOut
    }

    // MARK: connect + load

    private func connect(token: String) async {
        phase = .loading
        let c = PlexClient(accountToken: token)
        do {
            try await c.discoverServer()
            client = c
            serverName = c.serverName
            AudioPlayer.shared.onTimeline = { key, state, t, d in
                Task { await c.reportTimeline(ratingKey: key, state: state, timeMs: t, durationMs: d) }
            }
            let secs = try await c.musicSections()
            sections = secs
            if let first = secs.first {
                artists = try await c.artists(sectionKey: first.key)
            }
            async let pls = (try? await c.playlists()) ?? []
            playlists = await pls
            phase = .ready
        } catch {
            phase = .error("Could not reach your Plex server: \(error.localizedDescription)")
        }
    }

    // MARK: browse

    func albums(of artist: PlexMetadata) async -> [PlexMetadata] {
        (try? await client?.children(ratingKey: artist.ratingKey)) ?? []
    }

    func tracks(of album: PlexMetadata) async -> [PlexMetadata] {
        (try? await client?.children(ratingKey: album.ratingKey)) ?? []
    }

    // MARK: search (task #3)

    func runSearch(_ query: String) {
        Task {
            searchHits = (try? await client?.search(query)) ?? []
        }
    }

    // MARK: similar artists (task #4)

    func loadSimilar(for artist: PlexMetadata) {
        Task {
            var hits = (try? await client?.relatedArtists(ratingKey: artist.ratingKey)) ?? []
            if hits.isEmpty {
                // Fall back to Prism's imported edges, matched to the live library by name.
                let similarNames = similarFromImport(artist.title)
                hits = artists.filter { similarNames.contains($0.title) }
            }
            similarArtists = hits
        }
    }

    private func similarFromImport(_ artist: String) -> Set<String> {
        let rows = (try? AppDatabase.shared.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT similarName FROM similarArtist WHERE artistName = ? COLLATE NOCASE", arguments: [artist])
        }) ?? []
        return Set(rows)
    }

    // MARK: playlists (task #2)

    func reloadPlaylists() {
        Task { playlists = (try? await client?.playlists()) ?? [] }
    }

    func playlistTracks(_ playlist: PlexMetadata) async -> [PlexMetadata] {
        (try? await client?.playlistItems(id: playlist.ratingKey)) ?? []
    }

    func createPlaylist(title: String, from tracks: [PlexMetadata]) {
        Task {
            _ = try? await client?.createPlaylist(title: title, trackRatingKeys: tracks.map(\.ratingKey))
            reloadPlaylists()
        }
    }

    func addToPlaylist(_ playlist: PlexMetadata, tracks: [PlexMetadata]) {
        Task { try? await client?.addToPlaylist(id: playlist.ratingKey, trackRatingKeys: tracks.map(\.ratingKey)) }
    }

    /// Recreate an imported Prism playlist on the Plex server from its track
    /// ratingKeys (task #9 bridge).
    func recreatePrismPlaylist(named name: String) {
        let keys = (try? AppDatabase.shared.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT ratingKey FROM prismPlaylist WHERE name = ? AND ratingKey IS NOT NULL ORDER BY position", arguments: [name])
        }) ?? []
        guard !keys.isEmpty else { return }
        Task {
            _ = try? await client?.createPlaylist(title: name, trackRatingKeys: keys)
            reloadPlaylists()
        }
    }

    func importedPrismPlaylists() -> [String] { AppDatabase.shared.prismPlaylistNames() }

    func deletePlaylist(_ playlist: PlexMetadata) {
        Task {
            try? await client?.deletePlaylist(id: playlist.ratingKey)
            reloadPlaylists()
        }
    }

    // MARK: ratings (task #1) — persist locally AND push to Plex

    func rate(_ track: PlexMetadata, stars: Int) {
        AppDatabase.shared.setRating(stars, ratingKey: track.ratingKey, title: track.title, artist: track.grandparentTitle)
        AudioPlayer.shared.setCurrentRating(stars)
        Task { try? await client?.rate(ratingKey: track.ratingKey, stars: stars) }
    }

    func rateCurrent(stars: Int) {
        guard let t = AudioPlayer.shared.current else { return }
        AppDatabase.shared.setRating(stars, ratingKey: t.id, title: t.title, artist: t.artist)
        AudioPlayer.shared.setCurrentRating(stars)
        Task { try? await client?.rate(ratingKey: t.id, stars: stars) }
    }

    func rating(_ ratingKey: String) -> Int? { AppDatabase.shared.rating(forRatingKey: ratingKey) }

    // MARK: downloads (task #5)

    func download(_ m: PlexMetadata) {
        guard let part = m.firstPartKey, let url = client?.streamURL(partKey: part) else { return }
        DownloadManager.shared.download(ratingKey: m.ratingKey, from: url, title: m.title,
                                        artist: m.grandparentTitle, durationMs: m.duration ?? 0, codec: m.codec)
    }

    // MARK: playable resolution (local → native stream → transcode, task #7)

    func playable(_ m: PlexMetadata, albumTitle: String, artist: String) -> PlayableTrack? {
        let url: URL?
        if let local = DownloadManager.shared.localURL(m.ratingKey) {
            url = local
        } else if AudioCapability.canPlayNatively(m.codec) {
            url = m.firstPartKey.flatMap { client?.streamURL(partKey: $0) }
        } else {
            url = client?.transcodeURL(ratingKey: m.ratingKey)   // ape, wma, …
        }
        guard let url else { return nil }
        return PlayableTrack(
            id: m.ratingKey,
            title: m.title,
            artist: artist.isEmpty ? (m.grandparentTitle ?? "") : artist,
            album: albumTitle.isEmpty ? (m.parentTitle ?? "") : albumTitle,
            url: url,
            durationMs: m.duration ?? 0,
            artworkURL: client?.imageURL(thumb: m.thumb),
            userRating: rating(m.ratingKey) ?? m.userRating.map { Int($0 / 2) }
        )
    }

    /// Build playables for a list and start playback at `index`.
    func play(_ list: [PlexMetadata], startAt index: Int, albumTitle: String = "", artist: String = "") {
        let playables = list.compactMap { playable($0, albumTitle: albumTitle, artist: artist) }
        guard !playables.isEmpty else { return }
        AudioPlayer.shared.play(tracks: playables, startAt: min(index, playables.count - 1))
    }

    func imageURL(_ thumb: String?, size: Int = 300) -> URL? {
        client?.imageURL(thumb: thumb, size: size)
    }

    // MARK: offline playback

    func downloadedTracks() -> [TrackRecord] { AppDatabase.shared.downloadedTracks() }

    /// Play downloaded tracks straight from local files — works without the
    /// Plex server reachable.
    func playDownloaded(_ records: [TrackRecord], startAt index: Int) {
        let playables: [PlayableTrack] = records.compactMap { r in
            guard let path = r.localPath, let key = r.ratingKey else { return nil }
            return PlayableTrack(
                id: key, title: r.trackTitle ?? "Unknown",
                artist: r.artistName ?? "", album: r.albumTitle ?? "",
                url: URL(fileURLWithPath: path), durationMs: r.durationMs,
                artworkURL: nil, userRating: r.userRating
            )
        }
        guard !playables.isEmpty else { return }
        AudioPlayer.shared.play(tracks: playables, startAt: min(index, playables.count - 1))
    }

    // MARK: Prism import

    func runImport(prismDBPath: String) {
        importMessage = "Importing…"
        Task.detached {
            do {
                let s = try Importer.importProm(from: prismDBPath)
                await MainActor.run {
                    self.importMessage = "Imported \(s.tracks) tracks, \(s.plays) plays, \(s.tags) tag links, \(s.similar) similar, \(s.playlists) playlist entries."
                }
            } catch {
                await MainActor.run { self.importMessage = "Import failed: \(error.localizedDescription)" }
            }
        }
    }
}

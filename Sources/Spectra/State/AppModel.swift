import Foundation
import SwiftUI
import AppKit

/// Top-level app state: accounts, the active music provider, browsing, search,
/// playlists, ratings and offline downloads. Phase 2: the Plex client is one
/// provider behind `MusicProvider`, and several accounts can be configured.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case signedOut, linking, loading, ready, error(String) }
    enum Pane: Hashable { case library, playlists, search, downloads, settings }

    @Published var phase: Phase = .signedOut
    @Published var linkCode: String?          // shown while the user approves in-browser
    @Published var serverName = ""
    @Published var pane: Pane = .library
    @Published var artists: [PlexMetadata] = []
    @Published var playlists: [PlexMetadata] = []
    @Published var searchHits: [HubContainerResponse.Hub] = []
    @Published var similarArtists: [PlexMetadata] = []
    @Published var importMessage: String?

    // Multi-account (A2).
    @Published var accounts: [Account] = []
    @Published var activeAccountID: String?

    private(set) var provider: (any MusicProvider)?
    private let auth = PlexAuth()
    private let legacyTokenAccount = "plex.account.token"   // pre-multi-account key

    func bootstrap() {
        TrackNotifier.shared.requestAuthIfNeeded()
        AudioPlayer.shared.onTrackChange = { track in TrackNotifier.shared.notify(track) }

        AccountStore.shared.migrateLegacyIfNeeded(legacyAccount: legacyTokenAccount)
        refreshAccounts()
        if let active = AccountStore.shared.activeAccount {
            connect(account: active)
        } else {
            phase = .signedOut
        }
    }

    private func refreshAccounts() {
        accounts = AccountStore.shared.accounts
        activeAccountID = AccountStore.shared.activeAccount?.id
    }

    // MARK: sign-in / accounts (A2)

    /// Link a new Plex account via the plex.tv PIN flow and make it active.
    func startLink() {
        phase = .linking
        Task {
            do {
                let pin = try await auth.requestPIN()
                linkCode = pin.code
                NSWorkspace.shared.open(auth.authURL(code: pin.code))
                let token = try await auth.pollForToken(pin: pin)
                let account = Account(id: UUID().uuidString, kind: .plex, name: "Plex")
                AccountStore.shared.add(account, token: token)
                AccountStore.shared.activeID = account.id
                refreshAccounts()
                connect(account: account)
            } catch {
                phase = .error("Linking failed: \(error.localizedDescription)")
            }
        }
    }

    /// Present a folder picker and, on selection, add it as a Local Files
    /// account and make it active. The folder path is the account's "token".
    func promptAddLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose your music folder (an Artist / Album / Track layout works best)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addLocalAccount(path: url.path)
    }

    /// Add an anonymous YouTube Music account (search + play). Personal library
    /// via cookies is a later increment; the token is empty for now.
    func addYouTubeMusicAccount() {
        let account = Account(id: UUID().uuidString, kind: .youtubeMusic, name: "YouTube Music")
        AccountStore.shared.add(account, token: "")
        AccountStore.shared.activeID = account.id
        refreshAccounts()
        connect(account: account)
    }

    func addLocalAccount(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let account = Account(id: UUID().uuidString, kind: .local, name: name.isEmpty ? "Local" : name)
        AccountStore.shared.add(account, token: path)
        AccountStore.shared.activeID = account.id
        refreshAccounts()
        connect(account: account)
    }

    func switchAccount(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        AccountStore.shared.activeID = id
        refreshAccounts()
        connect(account: account)
    }

    /// Remove any account by id. If it was the active one, reconnect to the next
    /// remaining account, or drop to the sign-in screen.
    func removeAccount(_ id: String) {
        let wasActive = (id == activeAccountID)
        AccountStore.shared.remove(id)   // also repoints activeID if needed
        if wasActive {
            AudioPlayer.shared.onTimeline = nil
            provider = nil
            artists = []; playlists = []; searchHits = []; similarArtists = []; serverName = ""
        }
        refreshAccounts()
        if wasActive {
            if let next = AccountStore.shared.activeAccount { connect(account: next) }
            else { phase = .signedOut }
        }
    }

    /// Remove the active account; switch to another if one remains, else sign out.
    func signOut() {
        if let id = activeAccountID { AccountStore.shared.remove(id) }
        AudioPlayer.shared.onTimeline = nil
        provider = nil
        artists = []; playlists = []; searchHits = []; similarArtists = []; serverName = ""
        refreshAccounts()
        if let next = AccountStore.shared.activeAccount {
            connect(account: next)
        } else {
            phase = .signedOut
        }
    }

    // MARK: connect + load

    private func connect(account: Account) {
        guard let token = AccountStore.shared.token(for: account.id) else {
            phase = .error("No stored credentials for \(account.name).")
            return
        }
        phase = .loading
        let p = ProviderFactory.make(for: account, token: token)
        Task {
            do {
                try await p.connect()
                provider = p
                serverName = p.displayName.isEmpty ? account.name : p.displayName
                AudioPlayer.shared.onTimeline = { key, state, t, d in
                    Task { await p.reportTimeline(ratingKey: key, state: state, timeMs: t, durationMs: d) }
                }
                artists = (try? await p.artists()) ?? []
                playlists = (try? await p.playlists()) ?? []
                phase = .ready
            } catch {
                phase = .error("Could not connect to \(account.name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: browse

    func albums(of artist: PlexMetadata) async -> [PlexMetadata] {
        (try? await provider?.albums(of: artist)) ?? []
    }

    func tracks(of album: PlexMetadata) async -> [PlexMetadata] {
        (try? await provider?.tracks(of: album)) ?? []
    }

    // MARK: search

    func runSearch(_ query: String) {
        Task { searchHits = (try? await provider?.search(query)) ?? [] }
    }

    // MARK: similar artists

    func loadSimilar(for artist: PlexMetadata) {
        Task {
            var hits = (try? await provider?.relatedArtists(ratingKey: artist.ratingKey)) ?? []
            if hits.isEmpty {
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

    // MARK: playlists

    func reloadPlaylists() {
        Task { playlists = (try? await provider?.playlists()) ?? [] }
    }

    func playlistTracks(_ playlist: PlexMetadata) async -> [PlexMetadata] {
        (try? await provider?.playlistItems(id: playlist.ratingKey)) ?? []
    }

    func createPlaylist(title: String, from tracks: [PlexMetadata]) {
        Task {
            try? await provider?.createPlaylist(title: title, trackRatingKeys: tracks.map(\.ratingKey))
            reloadPlaylists()
        }
    }

    func addToPlaylist(_ playlist: PlexMetadata, tracks: [PlexMetadata]) {
        Task { try? await provider?.addToPlaylist(id: playlist.ratingKey, trackRatingKeys: tracks.map(\.ratingKey)) }
    }

    func recreatePrismPlaylist(named name: String) {
        let keys = (try? AppDatabase.shared.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT ratingKey FROM prismPlaylist WHERE name = ? AND ratingKey IS NOT NULL ORDER BY position", arguments: [name])
        }) ?? []
        guard !keys.isEmpty else { return }
        Task {
            try? await provider?.createPlaylist(title: name, trackRatingKeys: keys)
            reloadPlaylists()
        }
    }

    func importedPrismPlaylists() -> [String] { AppDatabase.shared.prismPlaylistNames() }

    func deletePlaylist(_ playlist: PlexMetadata) {
        Task {
            try? await provider?.deletePlaylist(id: playlist.ratingKey)
            reloadPlaylists()
        }
    }

    // MARK: ratings — persist locally AND push to the provider

    func rate(_ track: PlexMetadata, stars: Int) {
        AppDatabase.shared.setRating(stars, ratingKey: track.ratingKey, title: track.title, artist: track.grandparentTitle)
        AudioPlayer.shared.setCurrentRating(stars)
        Task { try? await provider?.rate(ratingKey: track.ratingKey, stars: stars) }
    }

    func rateCurrent(stars: Int) {
        guard let t = AudioPlayer.shared.current else { return }
        AppDatabase.shared.setRating(stars, ratingKey: t.id, title: t.title, artist: t.artist)
        AudioPlayer.shared.setCurrentRating(stars)
        Task { try? await provider?.rate(ratingKey: t.id, stars: stars) }
    }

    func rating(_ ratingKey: String) -> Int? { AppDatabase.shared.rating(forRatingKey: ratingKey) }

    // MARK: downloads

    func download(_ m: PlexMetadata) {
        guard let url = provider?.downloadURL(for: m) else { return }
        DownloadManager.shared.download(ratingKey: m.ratingKey, from: url, title: m.title,
                                        artist: m.grandparentTitle, durationMs: m.duration ?? 0, codec: m.codec)
    }

    // MARK: playable resolution (local → provider)

    private func makePlayable(_ m: PlexMetadata, url: URL, albumTitle: String, artist: String) -> PlayableTrack {
        PlayableTrack(
            id: m.ratingKey,
            title: m.title,
            artist: artist.isEmpty ? (m.grandparentTitle ?? "") : artist,
            album: albumTitle.isEmpty ? (m.parentTitle ?? "") : albumTitle,
            url: url,
            durationMs: m.duration ?? 0,
            artworkURL: provider?.artworkURL(m.thumb, size: 300),
            userRating: rating(m.ratingKey) ?? m.userRating.map { Int($0 / 2) }
        )
    }

    /// Synchronous resolution (Plex, Local Files): a direct/local URL.
    func playable(_ m: PlexMetadata, albumTitle: String, artist: String) -> PlayableTrack? {
        let url: URL? = DownloadManager.shared.localURL(m.ratingKey) ?? provider?.playableURL(for: m)
        guard let url else { return nil }
        return makePlayable(m, url: url, albumTitle: albumTitle, artist: artist)
    }

    /// Async resolution (streaming providers like YouTube Music): a network
    /// round-trip for the stream URL, falling back to a local download.
    func resolvedPlayable(_ m: PlexMetadata, albumTitle: String, artist: String) async -> PlayableTrack? {
        if let local = DownloadManager.shared.localURL(m.ratingKey) {
            return makePlayable(m, url: local, albumTitle: albumTitle, artist: artist)
        }
        guard let url = await provider?.resolveStreamURL(for: m) else { return nil }
        return makePlayable(m, url: url, albumTitle: albumTitle, artist: artist)
    }

    func play(_ list: [PlexMetadata], startAt index: Int, albumTitle: String = "", artist: String = "") {
        guard !list.isEmpty else { return }
        let start = min(max(index, 0), list.count - 1)
        if provider?.capabilities.resolvesStreamLazily == true {
            // Each URL is a network call: play the chosen track first (instant
            // start), then resolve the rest from there and append in order.
            let slice = Array(list[start...])
            Task {
                guard let head = await resolvedPlayable(slice[0], albumTitle: albumTitle, artist: artist) else { return }
                AudioPlayer.shared.play(tracks: [head], startAt: 0)
                for m in slice.dropFirst() {
                    if let p = await resolvedPlayable(m, albumTitle: albumTitle, artist: artist) {
                        AudioPlayer.shared.append(p)
                    }
                }
            }
        } else {
            let playables = list.compactMap { playable($0, albumTitle: albumTitle, artist: artist) }
            guard !playables.isEmpty else { return }
            AudioPlayer.shared.play(tracks: playables, startAt: min(start, playables.count - 1))
        }
    }

    /// Queue a single track (next or at the end), resolving the URL async so it
    /// works for every provider, streaming ones included.
    func enqueue(_ m: PlexMetadata, albumTitle: String, artist: String, playNext: Bool) {
        Task {
            guard let p = await resolvedPlayable(m, albumTitle: albumTitle, artist: artist) else { return }
            if playNext { AudioPlayer.shared.playNext(p) } else { AudioPlayer.shared.append(p) }
        }
    }

    func imageURL(_ thumb: String?, size: Int = 300) -> URL? {
        provider?.artworkURL(thumb, size: size)
    }

    /// Square cover from the web (iTunes, no key) for a local album that has no
    /// embedded/folder artwork. Returns nil for other providers or junk names.
    func remoteCover(for item: PlexMetadata) async -> URL? {
        guard provider?.kind == .local, item.type == "album" else { return nil }
        let artist = item.grandparentTitle ?? item.parentTitle ?? ""
        guard !artist.isEmpty, !["Singles", "Unknown Album"].contains(item.title) else { return nil }
        return await ArtworkCache.shared.remoteCover(artist: artist, title: item.title, isAlbum: true)
    }

    // MARK: offline playback

    func downloadedTracks() -> [TrackRecord] { AppDatabase.shared.downloadedTracks() }

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

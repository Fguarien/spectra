import Foundation
import SwiftUI
import AppKit

/// Top-level app state: accounts, the active music provider, browsing, search,
/// playlists, ratings and offline downloads. Phase 2: the Plex client is one
/// provider behind `MusicProvider`, and several accounts can be configured.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case signedOut, linking, loading, ready, error(String) }
    /// Sidebar destinations, Music.app layout (v2.0).
    enum Pane: Hashable {
        case recentlyAdded, artists, albums, songs, genres, downloads, search
        case loved                                  // ♥ (Favourite Songs)
        case playlist(PlexMetadata)                 // a source playlist
        case localPlaylist(Int64)                   // Spectra playlist (Radio ♥…)
    }

    @Published var phase: Phase = .signedOut
    @Published var linkCode: String?          // shown while the user approves in-browser
    @Published var serverName = ""
    @Published var statusLabel = "Connecting…"
    @Published var pane: Pane = {
        switch UserDefaults.standard.string(forKey: "sidebar.pane") {
        case "recentlyAdded": return .recentlyAdded
        case "artists": return .artists
        case "songs": return .songs
        case "genres": return .genres
        default: return .albums
        }
    }() {
        didSet {
            let name: String? = switch pane {
            case .recentlyAdded: "recentlyAdded"; case .artists: "artists"; case .albums: "albums"
            case .songs: "songs"; case .genres: "genres"; default: nil
            }
            if let name { UserDefaults.standard.set(name, forKey: "sidebar.pane") }
        }
    }
    /// Playlists of every connected account, by account ID.
    @Published private(set) var poolPlaylists: [String: [PlexMetadata]] = [:]
    /// Album opened from a grid (Music.app pushes a detail page).
    @Published var openAlbum: CatalogAlbum?
    @Published var artists: [PlexMetadata] = []
    @Published var playlists: [PlexMetadata] = []
    @Published var searchHits: [SearchSection] = []
    @Published var searchQuery = ""
    @Published var searching = false
    @Published var similarArtists: [PlexMetadata] = []
    @Published var importMessage: String?

    // Multi-account (A2).
    @Published var accounts: [Account] = []
    @Published var activeAccountID: String?

    private(set) var provider: (any MusicProvider)?

    // Every configured account stays connected in the background (E): search
    // fans out across all of them and "All Sources" merges their artists.
    private(set) var pool: [String: any MusicProvider] = [:]
    @Published private(set) var poolArtists: [String: [PlexMetadata]] = [:]
    @Published private(set) var poolStatus: [String: String] = [:]   // accountID → error text
    @Published private(set) var mergedArtists: [MergedArtist] = []
    private var searchTask: Task<Void, Never>?
    private var poolConnected: Set<String> = []
    private let auth = PlexAuth()
    private let legacyTokenAccount = "plex.account.token"   // pre-multi-account key

    func bootstrap() {
        // Grids draw hundreds of covers: keep them in the HTTP cache.
        URLCache.shared = URLCache(memoryCapacity: 128 << 20, diskCapacity: 1 << 30)
        TrackNotifier.shared.requestAuthIfNeeded()
        LastFM.shared.start()
        RadioBuilder.shared.model = self
        MiniPlayer.shared.model = self
        RadioBuilder.shared.start()
        reloadLocalPlaylists()
        DownloadManager.shared.resume = { [weak self] m in self?.download(m) ?? false }
        DownloadManager.shared.migrateLegacyDownloads()
        startBackups()
        AudioPlayer.shared.onTrackChange = { track in TrackNotifier.shared.notify(track) }
        // Report playback to whichever provider serves the current track.
        AudioPlayer.shared.onTimeline = { [weak self] key, state, t, d in
            guard let self else { return }
            let cur = AudioPlayer.shared.current
            let p = (cur?.id == key ? cur?.sourceAccountID : nil).flatMap { self.pool[$0] } ?? self.provider
            guard let p else { return }
            Task { await p.reportTimeline(ratingKey: key, state: state, timeMs: t, durationMs: d) }
        }

        AccountStore.shared.migrateLegacyIfNeeded(legacyAccount: legacyTokenAccount)
        refreshAccounts()
        CatalogStore.shared.load(accounts: accounts)
        // Re-list each connected source once its copy is an hour old.
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCatalog(force: false) }
        }
        if let active = AccountStore.shared.activeAccount {
            connect(account: active)
        } else {
            phase = .signedOut
        }
    }

    /// Re-list every connected source (forced from View → Refresh Library).
    func refreshCatalog(force: Bool) {
        for (id, p) in pool where poolConnected.contains(id) {
            if force { CatalogStore.shared.refresh(accountID: id, provider: p) }
            else { CatalogStore.shared.refreshIfStale(accountID: id, provider: p) }
        }
    }

    /// Every playlist of every source, in account order.
    var allPlaylists: [PlexMetadata] { accounts.flatMap { poolPlaylists[$0.id] ?? [] } }

    /// Play from the merged library. A long list (Songs: thousands) is cut to
    /// a window after the chosen song: streaming sources resolve each URL.
    func play(catalog list: [CatalogTrack], startAt index: Int) {
        guard list.indices.contains(index) else { return }
        let lazy = list[index...].prefix(50).contains { provider(for: $0.meta)?.capabilities.resolvesStreamLazily == true }
        let window = Array(list[index...].prefix(lazy ? 50 : 500))
        play(window.map(\.meta), startAt: 0)
    }

    func shuffle(catalog list: [CatalogTrack]) {
        guard !list.isEmpty else { return }
        AudioPlayer.shared.shuffle = false
        play(catalog: Array(list.shuffled().prefix(200)), startAt: 0)
    }

    private func refreshAccounts() {
        accounts = AccountStore.shared.accounts
        for a in accounts { CatalogStore.shared.kinds[a.id] = a.kind }
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

    /// Add a YouTube Music account. Picking the ytmusicapi `browser.json`
    /// unlocks the personal library (artists, albums, playlists, Liked Music);
    /// cancelling adds an anonymous account (search + play only).
    func promptAddYouTubeMusic() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use"
        panel.message = "Choose your ytmusicapi browser.json for your library, or Cancel for search-only."
        let defaultDir = (NSHomeDirectory() as NSString).appendingPathComponent("Developer/spectra-ytmusic")
        if FileManager.default.fileExists(atPath: defaultDir) {
            panel.directoryURL = URL(fileURLWithPath: defaultDir)
        }
        let authPath = panel.runModal() == .OK ? panel.url?.path : nil
        addYouTubeMusicAccount(authPath: authPath)
    }

    func addYouTubeMusicAccount(authPath: String?) {
        let account = Account(id: UUID().uuidString, kind: .youtubeMusic, name: "YouTube Music")
        AccountStore.shared.add(account, token: authPath ?? "")
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
        dropFromPool(id)
        if wasActive {
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
        if let id = activeAccountID { AccountStore.shared.remove(id); dropFromPool(id) }
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
        statusLabel = "Connecting to \(account.name)…"
        let id = account.id
        let p = pool[id] ?? ProviderFactory.make(for: account, token: token)
        Task {
            do {
                if !poolConnected.contains(id) { try await p.connect(); poolConnected.insert(id) }
                pool[id] = p
                poolStatus[id] = nil
                provider = p
                serverName = p.displayName.isEmpty ? account.name : p.displayName
                // Load artists and playlists concurrently (each may be a slow
                // bridge call for YouTube Music).
                async let a = p.artists()
                async let pl = p.playlists()
                artists = tag((try? await a) ?? [], id)
                playlists = tag((try? await pl) ?? [], id)
                setPoolArtists(id, artists)
                phase = .ready
                connectPool()
            } catch {
                phase = .error("Could not connect to \(account.name): \(error.localizedDescription)")
            }
        }
    }

    /// Connect every other account in the background. A failing account is
    /// recorded in `poolStatus` and never blocks the active one.
    private func connectPool() {
        for account in accounts where pool[account.id] == nil && account.id != activeAccountID {
            guard let token = AccountStore.shared.token(for: account.id) else { continue }
            let p = ProviderFactory.make(for: account, token: token)
            let id = account.id
            pool[id] = p   // reserve the slot so a second call doesn't reconnect
            Task {
                do {
                    try await p.connect()
                    poolConnected.insert(id)
                    let a = tag(try await p.artists(), id)
                    setPoolArtists(id, a)
                } catch {
                    pool[id] = nil   // retried on the next connect
                    poolStatus[id] = error.localizedDescription
                }
            }
        }
    }

    private func dropFromPool(_ id: String) {
        CatalogStore.shared.forget(accountID: id)
        poolPlaylists[id] = nil
        pool[id] = nil
        poolConnected.remove(id)
        poolStatus[id] = nil
        setPoolArtists(id, nil)
    }

    private func setPoolArtists(_ id: String, _ list: [PlexMetadata]?) {
        poolArtists[id] = list
        if list != nil, let p = pool[id] {
            CatalogStore.shared.refreshIfStale(accountID: id, provider: p)
            Task { poolPlaylists[id] = tag((try? await p.playlists()) ?? [], id) }
        }
        mergedArtists = MergedArtist.merge(poolArtists, order: accounts.map(\.id))
    }

    private func tag(_ list: [PlexMetadata], _ id: String?) -> [PlexMetadata] {
        list.map { $0.tagged(id) }
    }

    /// The provider that owns a row: its source account, else the active one.
    func provider(for m: PlexMetadata) -> (any MusicProvider)? {
        if let id = m.sourceAccountID, let p = pool[id] { return p }
        return provider
    }

    func account(for m: PlexMetadata) -> Account? {
        let id = m.sourceAccountID ?? activeAccountID
        return accounts.first { $0.id == id }
    }

    // MARK: browse

    func albums(of artist: PlexMetadata) async -> [PlexMetadata] {
        let src = artist.sourceAccountID ?? activeAccountID
        return tag((try? await provider(for: artist)?.albums(of: artist)) ?? [], src)
    }

    func tracks(of album: PlexMetadata) async -> [PlexMetadata] {
        let src = album.sourceAccountID ?? activeAccountID
        return tag((try? await provider(for: album)?.tracks(of: album)) ?? [], src)
    }

    // MARK: search — fan-out across every connected account

    /// Debounced search as the user types in the toolbar field.
    func scheduleSearch() {
        searchTask?.cancel()
        let q = searchQuery
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await performSearch(q)
        }
    }

    func runSearch(_ query: String) {
        searchTask?.cancel()
        searchTask = Task { await performSearch(query) }
    }

    private func performSearch(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchHits = []; searching = false; return }
        if pane != .search { pane = .search }
        searching = true
        let targets: [(Int, Account, any MusicProvider)] = accounts.enumerated().compactMap { i, acc in
            pool[acc.id].map { (i, acc, $0) }
        }
        var bucket: [(Int, [SearchSection])] = []
        await withTaskGroup(of: (Int, [SearchSection]).self) { group in
            for (i, acc, p) in targets {
                group.addTask {
                    let hubs = (try? await p.search(q)) ?? []
                    let sections = hubs.compactMap { hub -> SearchSection? in
                        let items = hub.items.map { $0.tagged(acc.id) }
                        guard !items.isEmpty else { return nil }
                        return SearchSection(account: acc, title: hub.title ?? (hub.type ?? "Results").capitalized,
                                             type: hub.type ?? "", items: items)
                    }
                    return (i, sections)
                }
            }
            for await r in group { bucket.append(r) }
        }
        guard !Task.isCancelled else { return }
        searchHits = bucket.sorted { $0.0 < $1.0 }.flatMap(\.1)
        searching = false
    }

    // MARK: similar artists

    func loadSimilar(for artist: PlexMetadata) {
        Task {
            let src = artist.sourceAccountID ?? activeAccountID
            var hits = tag((try? await provider(for: artist)?.relatedArtists(ratingKey: artist.ratingKey)) ?? [], src)
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
        let id = activeAccountID
        Task {
            let list = tag((try? await provider?.playlists()) ?? [], id)
            playlists = list
            if let id { poolPlaylists[id] = list }
        }
    }

    func playlistTracks(_ playlist: PlexMetadata) async -> [PlexMetadata] {
        tag((try? await provider(for: playlist)?.playlistItems(id: playlist.ratingKey)) ?? [],
            playlist.sourceAccountID ?? activeAccountID)
    }

    func createPlaylist(title: String, from tracks: [PlexMetadata]) {
        Task {
            try? await provider?.createPlaylist(title: title, trackRatingKeys: activeKeys(tracks))
            reloadPlaylists()
        }
    }

    func addToPlaylist(_ playlist: PlexMetadata, tracks: [PlexMetadata]) {
        Task { try? await provider?.addToPlaylist(id: playlist.ratingKey, trackRatingKeys: activeKeys(tracks)) }
    }

    /// Rating keys of the tracks that belong to the active account.
    private func activeKeys(_ tracks: [PlexMetadata]) -> [String] {
        tracks.filter { $0.sourceAccountID == nil || $0.sourceAccountID == activeAccountID }.map(\.ratingKey)
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
        let p = provider(for: track)
        Task { try? await p?.rate(ratingKey: track.ratingKey, stars: stars) }
    }

    func rateCurrent(stars: Int) {
        guard let t = AudioPlayer.shared.current else { return }
        AppDatabase.shared.setRating(stars, ratingKey: t.id, title: t.title, artist: t.artist)
        AudioPlayer.shared.setCurrentRating(stars)
        let p = t.sourceAccountID.flatMap { pool[$0] } ?? provider
        Task { try? await p?.rate(ratingKey: t.id, stars: stars) }
    }

    func rating(_ ratingKey: String) -> Int? { AppDatabase.shared.rating(forRatingKey: ratingKey) }

    // MARK: downloads

    /// Download one track onto the NAS. Parked when the share isn't mounted;
    /// returns false when it can't be started yet (account not connected), so
    /// a parked request stays parked.
    @discardableResult
    func download(_ m: PlexMetadata) -> Bool {
        guard Storage.isAvailable else { DownloadManager.shared.park(m); return true }
        if let id = m.sourceAccountID, pool[id] == nil || !poolConnected.contains(id) { return false }
        guard let p = provider(for: m) else { return false }
        let meta = DownloadManager.Meta(
            ratingKey: m.ratingKey, title: m.title, artist: m.grandparentTitle,
            album: m.parentTitle, index: m.index, durationMs: m.duration ?? 0,
            ext: (m.codec ?? "m4a").replacingOccurrences(of: "/", with: ""),
            coverURL: p.artworkURL(m.thumb, size: 1200))
        if let url = p.downloadURL(for: m) {
            DownloadManager.shared.download(meta, from: url)
        } else if p.capabilities.resolvesStreamLazily {
            // No fetchable URL (googlevideo answers a plain GET with 403): the
            // provider writes the file itself (yt-dlp, itag 140 = AAC/m4a).
            DownloadManager.shared.download(meta) { dest in try await p.downloadFile(for: m, to: dest) }
        }
        return true
    }

    /// Download every track of an album or playlist (two at a time), and
    /// remember the set so its row can show a downloaded badge.
    func downloadAll(_ tracks: [PlexMetadata], collection: PlexMetadata? = nil) {
        if let collection { DownloadManager.shared.remember(collection: collection, tracks: tracks) }
        for t in tracks where !DownloadManager.shared.isDownloaded(t.ratingKey) { download(t) }
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
            artworkURL: provider(for: m)?.artworkURL(m.thumb ?? m.parentThumb, size: 300),
            userRating: rating(m.ratingKey) ?? m.userRating.map { Int($0 / 2) },
            sourceAccountID: m.sourceAccountID ?? activeAccountID,
            sourceKind: account(for: m)?.kind,
            largeArtworkURL: provider(for: m)?.artworkURL(m.thumb ?? m.parentThumb, size: 1200),
            meta: m.sourceAccountID == nil ? m.tagged(activeAccountID) : m
        )
    }

    /// Synchronous resolution (Plex, Local Files): a direct/local URL.
    func playable(_ m: PlexMetadata, albumTitle: String, artist: String) -> PlayableTrack? {
        let url: URL? = DownloadManager.shared.localURL(m.ratingKey) ?? provider(for: m)?.playableURL(for: m)
        guard let url else { return nil }
        return makePlayable(m, url: url, albumTitle: albumTitle, artist: artist)
    }

    /// Async resolution (streaming providers like YouTube Music): a network
    /// round-trip for the stream URL, falling back to a local download.
    func resolvedPlayable(_ m: PlexMetadata, albumTitle: String, artist: String) async -> PlayableTrack? {
        if let local = DownloadManager.shared.localURL(m.ratingKey) {
            return makePlayable(m, url: local, albumTitle: albumTitle, artist: artist)
        }
        guard let url = await provider(for: m)?.resolveStreamURL(for: m) else { return nil }
        return makePlayable(m, url: url, albumTitle: albumTitle, artist: artist)
    }

    func play(_ list: [PlexMetadata], startAt index: Int, albumTitle: String = "", artist: String = "") {
        guard !list.isEmpty else { return }
        let start = min(max(index, 0), list.count - 1)
        // A mixed-source list (Radio ♥: Local + YouTube) takes the async path as
        // soon as one track needs it; the sync path would silently drop those.
        if list[start...].contains(where: { provider(for: $0)?.capabilities.resolvesStreamLazily == true }) {
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

    /// Artwork drawn by the provider that owns the row.
    func imageURL(for m: PlexMetadata, size: Int = 300) -> URL? {
        provider(for: m)?.artworkURL(m.thumb, size: size)
    }

    /// Square cover from the web (iTunes, no key) for a local album that has no
    /// embedded/folder artwork. Returns nil for other providers or junk names.
    func remoteCover(for item: PlexMetadata) async -> URL? {
        guard provider(for: item)?.kind == .local, item.type == "album" else { return nil }
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

    // MARK: ♥ likes, local playlists, Radio ♥

    @Published private(set) var localPlaylists: [LocalPlaylist] = []
    @Published private(set) var likesVersion = 0     // bumps so ♥ buttons redraw

    func reloadLocalPlaylists() { localPlaylists = AppDatabase.shared.localPlaylists() }

    func isLiked(_ m: PlexMetadata) -> Bool { AppDatabase.shared.isLiked(artist: m.grandparentTitle, title: m.title) }

    func isLikedCurrent() -> Bool {
        guard let t = AudioPlayer.shared.current else { return false }
        return AppDatabase.shared.isLiked(artist: t.artist, title: t.title)
    }

    /// Love / un-love; loving grows the « Radio ♥ » playlist in the background.
    func toggleLike(_ m: PlexMetadata) {
        let row = m.sourceAccountID == nil ? m.tagged(activeAccountID) : m
        let liked = AppDatabase.shared.toggleLike(row)
        likesVersion += 1
        if liked { RadioBuilder.shared.grow(from: row) }
    }

    func toggleLikeCurrent() {
        guard let t = AudioPlayer.shared.current else { return }
        let m = t.meta ?? PlexMetadata(ratingKey: t.id, title: t.title, type: "track",
                                       parentTitle: t.album, grandparentTitle: t.artist,
                                       duration: t.durationMs)
        toggleLike(m)
    }

    func localPlaylistTracks(_ p: LocalPlaylist) -> [PlexMetadata] { AppDatabase.shared.localPlaylistTracks(p.id) }

    func deleteLocalPlaylist(_ p: LocalPlaylist) {
        AppDatabase.shared.deleteLocalPlaylist(p.id)
        reloadLocalPlaylists()
    }

    func removeFromLocalPlaylist(_ p: LocalPlaylist, _ m: PlexMetadata) {
        AppDatabase.shared.removeFromLocalPlaylist(p.id, track: m)
        reloadLocalPlaylists()
    }

    /// Find a song by artist + title in the user's sources. The best MATCH
    /// wins across all sources; the source order (Local > Plex > YouTube Music)
    /// only breaks ties. An exact title beats a remaster tag, and live / demo /
    /// remix / rough-mix / instrumental takes are refused unless asked for —
    /// v1.14 took "No Quarter (rough mix… no vocal)" from Plex over the studio
    /// track because any title *starting with* the name was accepted.
    func findSong(artist: String, title: String) async -> PlexMetadata? {
        let wantArtist = MergedArtist.normalise(artist)
        let wantTitle = MergedArtist.normalise(title)
        let rank: [ProviderKind: Int] = [.local: 0, .plex: 1, .youtubeMusic: 2]
        let ordered = accounts.filter { poolConnected.contains($0.id) }
            .sorted { (rank[$0.kind] ?? 9) < (rank[$1.kind] ?? 9) }
        var best: (score: Int, srcRank: Int, m: PlexMetadata)?
        for acc in ordered {
            guard let p = pool[acc.id],
                  let hubs = try? await p.search("\(artist) \(title)") else { continue }
            let tracks = hubs.filter { ($0.type ?? "") == "track" || ($0.title ?? "").lowercased().contains("song") }
                .flatMap(\.items)
            for t in tracks {
                let a = MergedArtist.normalise(t.grandparentTitle ?? "")
                guard !a.isEmpty, a == wantArtist || a.contains(wantArtist) || wantArtist.contains(a),
                      let score = Self.titleScore(MergedArtist.normalise(t.title), want: wantTitle) else { continue }
                let r = rank[acc.kind] ?? 9
                if best == nil || (score, r) < (best!.score, best!.srcRank) { best = (score, r, t.tagged(acc.id)) }
            }
            if best?.score == 0 { break }   // exact match: later sources can't beat it
        }
        return best?.m
    }

    /// 0 = exact title, 1 = same title + a harmless tag (remaster, stereo mix,
    /// single/album version, radio edit), nil = another take or another song.
    static func titleScore(_ have: String, want: String) -> Int? {
        if have == want { return 0 }
        guard have.hasPrefix(want) else { return nil }
        let extra = String(have.dropFirst(want.count))
        // The rest must be an annotation, not more words: "time after time" is
        // another song than "time" (substring checks on "ft" matched "after").
        let tail = extra.trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || "([-–—".contains(tail.first!) || tail.hasPrefix("feat") else { return nil }
        let refused = ["live", "demo", "remix", "rough", "instrumental", "karaoke", "acoustic",
                       "sped up", "slowed", "rehearsal", "outtake", "take ", "no vocal", "a cappella", "cover"]
        if refused.contains(where: { extra.contains($0) && !want.contains($0) }) { return nil }
        let harmless = ["remaster", "stereo", "mono", "mix", "version", "edit", "deluxe", "bonus", "feat"]
        return harmless.contains(where: { tail.contains($0) })
            || tail.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).isEmpty ? 1 : nil
    }

    // MARK: database backups on the NAS

    @Published var backupMessage: String?
    private var backupTimer: Timer?

    private func startBackups() {
        backupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.backupNow(quiet: true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            _ = try? AppDatabase.shared.backupToNAS()
        }
        backupNow(quiet: true)
    }

    func backupNow(quiet: Bool = false) {
        do {
            if let url = try AppDatabase.shared.backupToNAS() {
                backupMessage = "Backed up to \(url.lastPathComponent)"
            } else if !quiet {
                backupMessage = "NAS share not mounted — backup skipped."
            }
        } catch {
            backupMessage = "Backup failed: \(error.localizedDescription)"
        }
    }

    func promptRestore() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Spectra backup to restore (replaces ratings, history, playlists)"
        panel.directoryURL = Storage.root.appendingPathComponent("Backup")
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try AppDatabase.shared.backupToNAS()   // safety copy of the current state first
            try AppDatabase.shared.restore(from: url)
            backupMessage = "Restored \(url.lastPathComponent)."
        } catch {
            backupMessage = "Restore failed: \(error.localizedDescription)"
        }
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

/// One provider's slice of a search result (e.g. "YouTube Music — Songs").
struct SearchSection: Identifiable {
    let account: Account
    let title: String
    let type: String          // "track", "album", "artist", "playlist"…
    let items: [PlexMetadata]
    var id: String { "\(account.id)|\(type)|\(title)" }
}

/// An artist as it appears across every account, merged by normalised name.
struct MergedArtist: Identifiable, Hashable {
    let key: String
    let name: String
    let members: [PlexMetadata]   // one row per account that has the artist
    var id: String { key }

    static func normalise(_ name: String) -> String {
        var n = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasPrefix("the ") { n.removeFirst(4) }
        return n.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func merge(_ pool: [String: [PlexMetadata]], order: [String]) -> [MergedArtist] {
        var byKey: [String: [PlexMetadata]] = [:]
        var display: [String: String] = [:]
        for id in order {
            for a in pool[id] ?? [] {
                let k = normalise(a.title)
                guard !k.isEmpty else { continue }
                byKey[k, default: []].append(a)
                if display[k] == nil { display[k] = a.title }
            }
        }
        return byKey.map { MergedArtist(key: $0.key, name: display[$0.key] ?? $0.key, members: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

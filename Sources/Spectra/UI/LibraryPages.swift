import SwiftUI

// MARK: - shared bits

extension CatalogTrack {
    /// Wrap a provider row (playlist item, ♥) so it shows in the same table.
    init(meta m: PlexMetadata, addedAt: Date = .distantPast) {
        let artist = m.grandparentTitle ?? ""
        self.init(accountID: m.sourceAccountID ?? "", ratingKey: m.ratingKey, title: m.title,
                  artist: artist, album: m.parentTitle ?? "",
                  albumArtist: CatalogStore.primaryArtist(artist), trackNo: m.index, disc: m.parentIndex,
                  durationMs: m.duration ?? 0, year: m.parentYear ?? m.year, genre: m.Genre?.first?.tag,
                  addedAt: m.addedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? addedAt, meta: m)
    }
}

extension AppModel {
    func coverURL(_ t: CatalogTrack?, size: Int) -> URL? {
        guard let t else { return nil }
        return provider(for: t.meta)?.artworkURL(t.meta.thumb ?? t.meta.parentThumb, size: size)
    }
}

func formatDuration(ms: Int) -> String {
    guard ms > 0 else { return "" }
    let s = ms / 1000
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

func formatTotal(ms: Int, songs: Int) -> String {
    let min = ms / 60000
    let dur = min >= 60 ? "\(min / 60) h \(min % 60) min" : "\(min) min"
    return "\(songs) song\(songs == 1 ? "" : "s")" + (ms > 0 ? ", \(dur)" : "")
}

/// Square cover that fills its cell (grids, headers).
struct CoverView: View {
    let url: URL?
    var radius: CGFloat = 6

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: url) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.tertiary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }
}

/// Source badge drawn on a cover's top-right corner: one glyph per library
/// the album / song comes from (Plex, local folder, YouTube Music).
struct CoverSourceBadge: View {
    @EnvironmentObject var model: AppModel
    let accountIDs: [String]

    var body: some View {
        let accs = accountIDs.compactMap { id in model.accounts.first { $0.id == id } }
        if !accs.isEmpty {
            HStack(spacing: 4) {
                ForEach(accs) { acc in
                    Image(systemName: acc.kind.systemImage).help(acc.name)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(6)
        }
    }
}

/// Grid ↔ list switch shown in the toolbar of pages that have both.
enum ViewMode: String { case grid, list }

struct ViewModePicker: View {
    @Binding var mode: ViewMode
    var body: some View {
        Picker("View", selection: $mode) {
            Image(systemName: "square.grid.2x2").tag(ViewMode.grid).help("View as Grid")
            Image(systemName: "list.bullet").tag(ViewMode.list).help("View as List")
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

/// Large page title, Music-style.
struct PageTitle: View {
    let text: String
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.system(size: 26, weight: .bold))
            if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)
    }
}

// MARK: - albums (grid / list)

struct AlbumsPage: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let albums: [CatalogAlbum]
    let modeKey: String
    @State private var mode: ViewMode = .grid

    var body: some View {
        Group {
            if albums.isEmpty {
                EmptyState(text: CatalogStore.shared.syncing.isEmpty ? "No albums" : "Loading your library…")
            } else if mode == .grid {
                ScrollView {
                    PageTitle(text: title)
                    AlbumGrid(albums: albums).padding(.horizontal, 24).padding(.bottom, 24)
                }
            } else {
                VStack(spacing: 0) {
                    PageTitle(text: title)
                    AlbumTable(albums: albums, key: modeKey)
                }
            }
        }
        .toolbar { ToolbarItem { ViewModePicker(mode: $mode) } }
        .onAppear { mode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "mode.\(modeKey)") ?? "") ?? .grid }
        .onChange(of: mode) { _, m in UserDefaults.standard.set(m.rawValue, forKey: "mode.\(modeKey)") }
    }
}

struct AlbumGrid: View {
    @EnvironmentObject var model: AppModel
    let albums: [CatalogAlbum]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 230), spacing: 22, alignment: .top)],
                  alignment: .leading, spacing: 26) {
            ForEach(albums) { AlbumCell(album: $0) }
        }
    }
}

struct AlbumCell: View {
    @EnvironmentObject var model: AppModel
    let album: CatalogAlbum
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CoverView(url: model.coverURL(album.coverTrack, size: 500))
                .overlay(alignment: .topTrailing) { CoverSourceBadge(accountIDs: album.accountIDs) }
                .overlay(alignment: .bottomLeading) {
                    if hover {
                        HStack {
                            Button { model.play(catalog: album.tracks, startAt: 0) } label: {
                                Image(systemName: "play.circle.fill").font(.system(size: 30))
                            }
                            Spacer()
                            Menu { AlbumMenu(album: album) } label: {
                                Image(systemName: "ellipsis.circle.fill").font(.system(size: 26))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(8)
                    }
                }
                .onHover { hover = $0 }
                .onTapGesture(count: 2) { model.play(catalog: album.tracks, startAt: 0) }
                .onTapGesture { model.openAlbum = album }
            HStack(spacing: 4) {
                Text(album.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                CollectionBadge(trackKeys: album.tracks.map(\.ratingKey))
            }
            Text(album.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .contextMenu { AlbumMenu(album: album) }
    }
}

struct AlbumMenu: View {
    @EnvironmentObject var model: AppModel
    let album: CatalogAlbum

    var body: some View {
        Button("Play") { model.play(catalog: album.tracks, startAt: 0) }
        Button("Shuffle") { model.shuffle(catalog: album.tracks) }
        Button("Play Next") { for t in album.tracks.reversed() { model.enqueue(t.meta, albumTitle: album.title, artist: album.artist, playNext: true) } }
        Button("Play Later") { for t in album.tracks { model.enqueue(t.meta, albumTitle: album.title, artist: album.artist, playNext: false) } }
        Divider()
        AddToPlaylistMenu(tracks: album.tracks.map(\.meta))
        Button("Download Album") { model.downloadAll(album.tracks.map(\.meta), collection: album.tracks.first?.meta) }
        Divider()
        Button("Go to Artist") { model.openAlbum = nil; model.pane = .artists; ArtistsPage.pending = album.artist }
    }
}

struct AlbumTable: View {
    @EnvironmentObject var model: AppModel
    let albums: [CatalogAlbum]
    let key: String
    @State private var sortOrder: [KeyPathComparator<CatalogAlbum>] = []
    @State private var selection: Set<CatalogAlbum.ID> = []

    var body: some View {
        Table(sortOrder.isEmpty ? albums : albums.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Album", value: \.title, comparator: .localizedStandard) { a in
                HStack(spacing: 8) {
                    ArtworkView(url: model.coverURL(a.coverTrack, size: 80), side: 28)
                    Text(a.title).lineLimit(1)
                    CollectionBadge(trackKeys: a.tracks.map(\.ratingKey))
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Artist", value: \.artist, comparator: .localizedStandard)
            TableColumn("Year", value: \.sortYear) { a in Text(a.year.map(String.init) ?? "") }.width(50)
            TableColumn("Genre", value: \.sortGenre) { a in Text(a.genre ?? "") }
            TableColumn("Songs", value: \.tracks.count) { a in Text("\(a.tracks.count)") }.width(50)
            TableColumn("Date Added", value: \.addedAt) { a in
                Text(a.addedAt == .distantPast ? "" : a.addedAt.formatted(date: .abbreviated, time: .omitted))
            }
            .width(100)
        }
        .contextMenu(forSelectionType: CatalogAlbum.ID.self) { ids in
            if let a = albums.first(where: { ids.contains($0.id) }) { AlbumMenu(album: a) }
        } primaryAction: { ids in
            if let a = albums.first(where: { ids.contains($0.id) }) { model.openAlbum = a }
        }
    }
}

extension CatalogAlbum {
    var sortYear: Int { year ?? 0 }
    var sortGenre: String { genre ?? "" }
}

// MARK: - album detail

struct AlbumDetailView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    let album: CatalogAlbum

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 24) {
                    CoverView(url: model.coverURL(album.coverTrack, size: 900), radius: 8)
                        .overlay(alignment: .topTrailing) { CoverSourceBadge(accountIDs: album.accountIDs) }
                        .frame(width: 250, height: 250)
                        .shadow(radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                        Button(album.artist) {
                            model.openAlbum = nil; ArtistsPage.pending = album.artist; model.pane = .artists
                        }
                        .buttonStyle(.plain).font(.system(size: 22)).foregroundStyle(.tint)
                        Text([album.genre?.uppercased(), album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button { model.play(catalog: album.tracks, startAt: 0) } label: {
                                Label("Play", systemImage: "play.fill").frame(width: 90)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { model.shuffle(catalog: album.tracks) } label: {
                                Label("Shuffle", systemImage: "shuffle").frame(width: 90)
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer().frame(width: 8)
                            CollectionBadge(trackKeys: album.tracks.map(\.ratingKey))
                            Menu { AlbumMenu(album: album) } label: { Image(systemName: "ellipsis") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        .controlSize(.large)
                        .padding(.top, 10)
                    }
                    Spacer()
                }
                VStack(spacing: 0) {
                    ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                        AlbumTrackRow(track: t, number: t.trackNo ?? (i + 1), striped: i % 2 == 1)
                            .onTapGesture(count: 2) { model.play(catalog: album.tracks, startAt: i) }
                            .contextMenu { SongsMenu(tracks: [t], context: album.tracks) }
                    }
                }
                Text(formatTotal(ms: album.durationMs, songs: album.tracks.count))
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("From").font(.caption).foregroundStyle(.tertiary)
                    ForEach(album.accountIDs, id: \.self) { SourceIcon(accountID: $0) }
                }
            }
            .padding(28)
        }
    }
}

struct AlbumTrackRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    let track: CatalogTrack
    let number: Int
    let striped: Bool
    @State private var hover = false

    var body: some View {
        let _ = model.likesVersion
        let playing = player.current?.id == track.ratingKey
        HStack(spacing: 10) {
            ZStack {
                if playing {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                } else if hover {
                    Image(systemName: "play.fill").font(.caption)
                } else {
                    Text("\(number)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 26, alignment: .trailing)
            Text(track.title).lineLimit(1).foregroundStyle(playing ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            if track.artist != track.albumArtist {
                Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            OfflineBadge(ratingKey: track.ratingKey)
            if model.isLiked(track.meta) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
            SourceIcon(accountID: track.accountID)
            Text(formatDuration(ms: track.durationMs)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(striped ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - songs (table)

struct SongsPage: View {
    @ObservedObject private var catalog = CatalogStore.shared

    var body: some View {
        VStack(spacing: 0) {
            PageTitle(text: "Songs", subtitle: catalog.tracks.isEmpty ? nil : "\(catalog.tracks.count)")
            if catalog.tracks.isEmpty {
                EmptyState(text: catalog.syncing.isEmpty ? "No songs" : "Loading your library…")
            } else {
                SongsTable(tracks: catalog.tracks, key: "songs", defaultSort: [KeyPathComparator(\.title, comparator: .localizedStandard)])
            }
        }
    }
}

/// Music's song list: sortable, resizable, hideable columns (right-click the
/// header), remembered per page. Double-click plays from that row.
struct SongsTable: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    let tracks: [CatalogTrack]
    let key: String
    var showNumber = false
    var onRemove: ((CatalogTrack) -> Void)? = nil
    @State private var sortOrder: [KeyPathComparator<CatalogTrack>]
    @State private var selection: Set<CatalogTrack.ID> = []
    @State private var columns: TableColumnCustomization<CatalogTrack>

    init(tracks: [CatalogTrack], key: String, showNumber: Bool = false,
         defaultSort: [KeyPathComparator<CatalogTrack>] = [], onRemove: ((CatalogTrack) -> Void)? = nil) {
        self.tracks = tracks; self.key = key; self.showNumber = showNumber; self.onRemove = onRemove
        _sortOrder = State(initialValue: defaultSort)
        let saved = UserDefaults.standard.data(forKey: "table.\(key)")
            .flatMap { try? JSONDecoder().decode(TableColumnCustomization<CatalogTrack>.self, from: $0) }
        _columns = State(initialValue: saved ?? TableColumnCustomization())
    }

    private var rows: [CatalogTrack] { sortOrder.isEmpty ? tracks : tracks.sorted(using: sortOrder) }

    var body: some View {
        let _ = model.likesVersion
        let rows = self.rows
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("") { t in
                let playing = player.current?.id == t.ratingKey
                HStack(spacing: 2) {
                    if playing {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                    } else if showNumber, let i = rows.firstIndex(of: t) {
                        Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    OfflineBadge(ratingKey: t.ratingKey)
                }
            }
            .width(min: 24, ideal: 30, max: 50)
            .customizationID("status")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Title", value: \.title, comparator: .localizedStandard) { t in
                Text(t.title).lineLimit(1)
                    .foregroundStyle(player.current?.id == t.ratingKey ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .width(min: 120, ideal: 260)
            .customizationID("title")
            TableColumn("♥") { t in
                if model.isLiked(t.meta) { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
            }
            .width(22)
            .customizationID("love")
            TableColumn("Time", value: \.durationMs) { t in
                Text(formatDuration(ms: t.durationMs)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50, max: 80)
            .customizationID("time")
            TableColumn("Artist", value: \.artist, comparator: .localizedStandard)
                .width(min: 80, ideal: 180)
                .customizationID("artist")
            TableColumn("Album", value: \.album, comparator: .localizedStandard)
                .width(min: 80, ideal: 200)
                .customizationID("album")
            TableColumn("Genre", value: \.sortGenre, comparator: .localizedStandard) { t in Text(t.genre ?? "") }
                .width(min: 60, ideal: 110)
                .customizationID("genre")
            TableColumn("Year", value: \.sortYear) { t in Text(t.year.map(String.init) ?? "") }
                .width(min: 40, ideal: 50, max: 70)
                .customizationID("year")
                .defaultVisibility(.hidden)
            TableColumn("Date Added", value: \.addedAt) { t in
                Text(t.addedAt == .distantPast ? "" : t.addedAt.formatted(date: .abbreviated, time: .omitted))
            }
            .width(min: 70, ideal: 100)
            .customizationID("added")
            .defaultVisibility(.hidden)
            TableColumn("Source") { t in SourceIcon(accountID: t.accountID) }
                .width(min: 30, ideal: 44, max: 60)
                .customizationID("source")
        }
        .contextMenu(forSelectionType: CatalogTrack.ID.self) { ids in
            let picked = rows.filter { ids.contains($0.id) }
            if !picked.isEmpty { SongsMenu(tracks: picked, context: rows, onRemove: onRemove) }
        } primaryAction: { ids in
            if let i = rows.firstIndex(where: { ids.contains($0.id) }) { model.play(catalog: rows, startAt: i) }
        }
        .onChange(of: columns) { _, c in
            UserDefaults.standard.set(try? JSONEncoder().encode(c), forKey: "table.\(key)")
        }
    }
}

/// Right-click on one or more songs.
struct SongsMenu: View {
    @EnvironmentObject var model: AppModel
    let tracks: [CatalogTrack]
    var context: [CatalogTrack] = []
    var onRemove: ((CatalogTrack) -> Void)? = nil

    var body: some View {
        let first = tracks[0]
        Button("Play") {
            if let i = context.firstIndex(of: first) { model.play(catalog: context, startAt: i) }
            else { model.play(catalog: tracks, startAt: 0) }
        }
        Button("Play Next") { for t in tracks.reversed() { model.enqueue(t.meta, albumTitle: t.album, artist: t.artist, playNext: true) } }
        Button("Play Later") { for t in tracks { model.enqueue(t.meta, albumTitle: t.album, artist: t.artist, playNext: false) } }
        Divider()
        Button(model.isLiked(first.meta) ? "Unlove ♥" : "Love ♥") { for t in tracks { model.toggleLike(t.meta) } }
        if tracks.count == 1 {
            Menu("Rate") {
                ForEach(0...5, id: \.self) { n in
                    Button(n == 0 ? "No rating" : String(repeating: "★", count: n)) { model.rate(first.meta, stars: n) }
                }
            }
        }
        AddToPlaylistMenu(tracks: tracks.map(\.meta))
        Divider()
        if tracks.allSatisfy({ DownloadManager.shared.isDownloaded($0.ratingKey) }) {
            Button("Remove Download") { for t in tracks { DownloadManager.shared.removeDownload(ratingKey: t.ratingKey) } }
        } else {
            Button("Download") { model.downloadAll(tracks.map(\.meta)) }
        }
        Divider()
        Button("Go to Album") {
            if let a = CatalogStore.shared.albums.first(where: { $0.id == first.albumKey }) { model.openAlbum = a }
        }
        Button("Go to Artist") { model.openAlbum = nil; ArtistsPage.pending = first.albumArtist; model.pane = .artists }
        if let onRemove {
            Divider()
            Button("Remove from Playlist", role: .destructive) { for t in tracks { onRemove(t) } }
        }
    }
}

/// « Add to Playlist » → Spectra playlists, then the active account's.
struct AddToPlaylistMenu: View {
    @EnvironmentObject var model: AppModel
    let tracks: [PlexMetadata]

    var body: some View {
        Menu("Add to Playlist") {
            ForEach(model.localPlaylists) { pl in
                Button(pl.name) {
                    _ = AppDatabase.shared.append(tracks, toPlaylist: pl.id)
                    model.reloadLocalPlaylists()
                }
            }
            if !model.localPlaylists.isEmpty && !model.playlists.isEmpty { Divider() }
            ForEach(model.playlists) { pl in
                Button(pl.title) { model.addToPlaylist(pl, tracks: tracks) }
            }
            Divider()
            Button("New Playlist…") { model.newLocalPlaylist(with: tracks) }
        }
    }
}

// MARK: - artists

struct ArtistsPage: View {
    /// Artist to select when arriving from « Go to Artist ».
    @MainActor static var pending: String?
    @EnvironmentObject var model: AppModel
    @ObservedObject private var catalog = CatalogStore.shared
    @State private var selected: CatalogArtist.ID?
    @State private var filter = ""
    @State private var mode: ViewMode = .list
    @State private var gridOpen: CatalogArtist.ID?

    var body: some View {
        Group {
            if mode == .grid { grid } else { split }
        }
        .toolbar { ToolbarItem { ViewModePicker(mode: $mode) } }
        .onAppear {
            mode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "mode.artists") ?? "") ?? .list
            takePending()
        }
        .onChange(of: mode) { _, m in UserDefaults.standard.set(m.rawValue, forKey: "mode.artists") }
        .onChange(of: model.pane) { _, _ in takePending() }
    }

    /// Grid: round artist pictures; a click opens the artist page, with a
    /// back button to the grid.
    @ViewBuilder private var grid: some View {
        if let a = catalog.artists.first(where: { $0.id == gridOpen }) {
            VStack(alignment: .leading, spacing: 0) {
                Button { gridOpen = nil } label: { Label("Artists", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).padding([.top, .leading], 16)
                ArtistDetail(artist: a)
            }
        } else if catalog.artists.isEmpty {
            EmptyState(text: catalog.syncing.isEmpty ? "No artists" : "Loading your library…")
        } else {
            ScrollView {
                PageTitle(text: "Artists", subtitle: "\(catalog.artists.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 22, alignment: .top)],
                          alignment: .leading, spacing: 26) {
                    ForEach(catalog.artists) { a in
                        VStack(spacing: 8) {
                            CoverView(url: model.coverURL(a.albums.first?.coverTrack, size: 400), radius: 0)
                                .clipShape(Circle())
                            Text(a.name).font(.callout.weight(.medium)).lineLimit(1)
                            Text(a.albums.count == 1 ? "1 album" : "\(a.albums.count) albums")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { gridOpen = a.id }
                        .contextMenu {
                            Button("Play") { model.play(catalog: a.albums.flatMap(\.tracks), startAt: 0) }
                            Button("Shuffle") { model.shuffle(catalog: a.albums.flatMap(\.tracks)) }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
    }

    private var split: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder).padding(8)
                List(selection: $selected) {
                    ForEach(visible) { a in
                        HStack(spacing: 10) {
                            ArtworkView(url: model.coverURL(a.albums.first?.coverTrack, size: 80), side: 30)
                                .clipShape(Circle())
                            Text(a.name).lineLimit(1)
                        }
                        .tag(a.id)
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 180, idealWidth: CGFloat(UserDefaults.standard.double(forKey: "column.artists.list")).nonZero ?? 240,
                   maxWidth: 420)
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.size.width) { _, w in UserDefaults.standard.set(Double(w), forKey: "column.artists.list") }
            })

            Group {
                if let a = catalog.artists.first(where: { $0.id == selected }) {
                    ArtistDetail(artist: a)
                } else {
                    EmptyState(text: catalog.artists.isEmpty ? "No artists" : "Select an artist")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var visible: [CatalogArtist] {
        let f = MergedArtist.normalise(filter)
        return f.isEmpty ? catalog.artists : catalog.artists.filter { $0.id.contains(f) }
    }

    private func takePending() {
        if let p = Self.pending {
            selected = MergedArtist.normalise(p); gridOpen = selected; Self.pending = nil
        } else if selected == nil {
            selected = catalog.artists.first?.id
        }
    }
}

private extension CGFloat {
    var nonZero: CGFloat? { self > 0 ? self : nil }
}

/// Music's artist page: every album with its songs, newest first.
struct ArtistDetail: View {
    @EnvironmentObject var model: AppModel
    let artist: CatalogArtist

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Text(artist.name).font(.system(size: 30, weight: .bold))
                    Spacer()
                    Button { model.shuffle(catalog: artist.albums.flatMap(\.tracks)) } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                ForEach(artist.albums.reversed()) { album in
                    HStack(alignment: .top, spacing: 20) {
                        CoverView(url: model.coverURL(album.coverTrack, size: 500))
                            .overlay(alignment: .topTrailing) { CoverSourceBadge(accountIDs: album.accountIDs) }
                            .frame(width: 170, height: 170)
                            .onTapGesture { model.openAlbum = album }
                            .contextMenu { AlbumMenu(album: album) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title).font(.title3.weight(.bold))
                            Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.bottom, 6)
                            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { i, t in
                                AlbumTrackRow(track: t, number: t.trackNo ?? (i + 1), striped: i % 2 == 1)
                                    .onTapGesture(count: 2) { model.play(catalog: album.tracks, startAt: i) }
                                    .contextMenu { SongsMenu(tracks: [t], context: album.tracks) }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - genres

struct GenresPage: View {
    @ObservedObject private var catalog = CatalogStore.shared
    @State private var selected: CatalogGenre.ID?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(catalog.genres) { g in
                    HStack { Text(g.name); Spacer(); Text("\(g.albums.count)").foregroundStyle(.secondary) }.tag(g.id)
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 160, idealWidth: 220, maxWidth: 360)

            Group {
                if let g = catalog.genres.first(where: { $0.id == selected }) {
                    ScrollView {
                        PageTitle(text: g.name)
                        AlbumGrid(albums: g.albums).padding(.horizontal, 24).padding(.bottom, 24)
                    }
                } else {
                    EmptyState(text: catalog.genres.isEmpty ? "No genres (YouTube Music gives none)" : "Select a genre")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selected == nil { selected = catalog.genres.first?.id } }
    }
}

// MARK: - playlists

struct PlaylistPage: View {
    enum Source { case loved, remote(PlexMetadata), local(LocalPlaylist) }

    @EnvironmentObject var model: AppModel
    let source: Source
    @State private var tracks: [CatalogTrack] = []
    @State private var loading = false
    @State private var mode: ViewMode = .list

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if loading && tracks.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                EmptyState(text: emptyText)
            } else if mode == .grid {
                ScrollView { PlaylistArtGrid(tracks: tracks).padding(24) }
            } else {
                SongsTable(tracks: tracks, key: "playlist", showNumber: true, onRemove: removeAction)
            }
        }
        .toolbar { ToolbarItem { ViewModePicker(mode: $mode) } }
        .task(id: identity) { await load() }
        .onChange(of: model.likesVersion) { _, _ in if case .loved = source { Task { await load() } } }
    }

    private var identity: String {
        switch source {
        case .loved: return "loved"
        case .remote(let p): return "r:\(p.id)"
        case .local(let p): return "l:\(p.id):\(p.count)"
        }
    }

    private var title: String {
        switch source {
        case .loved: return "Favourite Songs"
        case .remote(let p): return p.title
        case .local(let p): return p.name
        }
    }

    private var isLocal: Bool { if case .local = source { return true } else { return false } }

    private var emptyText: String {
        if case .loved = source { return "Love a song (♥) and it shows up here" }
        return "This playlist is empty"
    }

    private var removeAction: ((CatalogTrack) -> Void)? {
        switch source {
        case .local(let p): return { t in model.removeFromLocalPlaylist(p, t.meta); Task { await load() } }
        case .loved: return { t in model.toggleLike(t.meta) }
        case .remote: return nil
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 22) {
            PlaylistMosaic(tracks: Array(tracks.prefix(4)))
                .frame(width: 180, height: 180)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 28, weight: .bold)).lineLimit(2)
                    .onTapGesture(count: 2) { if case .local(let p) = source { model.renameLocalPlaylist(p) } }
                    .help(isLocal ? "Double-click to rename" : "")
                HStack(spacing: 6) {
                    Text(formatTotal(ms: tracks.reduce(0) { $0 + $1.durationMs }, songs: tracks.count))
                    if case .remote(let p) = source { SourceIcon(accountID: p.sourceAccountID) }
                    CollectionBadge(trackKeys: tracks.map(\.ratingKey))
                }
                .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { model.play(catalog: tracks, startAt: 0) } label: {
                        Label("Play", systemImage: "play.fill").frame(width: 90)
                    }
                    Button { model.shuffle(catalog: tracks) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(width: 90)
                    }
                    Button { download() } label: { Image(systemName: "arrow.down.circle") }
                        .buttonStyle(.borderless).help("Download Playlist")
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(24)
    }

    private func download() {
        switch source {
        case .remote(let p): model.downloadAll(tracks.map(\.meta), collection: p)
        default: model.downloadAll(tracks.map(\.meta))
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let metas: [PlexMetadata]
        switch source {
        case .loved: metas = AppDatabase.shared.likedTracks()
        case .remote(let p): metas = await model.playlistTracks(p)
        case .local(let p): metas = model.localPlaylistTracks(p)
        }
        tracks = metas.map { CatalogTrack(meta: $0) }
    }
}

/// 2×2 cover mosaic for a playlist (one cover when there's a single song).
struct PlaylistMosaic: View {
    @EnvironmentObject var model: AppModel
    let tracks: [CatalogTrack]

    var body: some View {
        Group {
            if tracks.count < 4 {
                CoverView(url: model.coverURL(tracks.first, size: 600), radius: 8)
            } else {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { cell(0); cell(1) }
                    GridRow { cell(2); cell(3) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
        }
    }

    private func cell(_ i: Int) -> some View {
        CoverView(url: model.coverURL(tracks[i], size: 300), radius: 0).shadow(radius: 0)
    }
}

/// « Grid » mode for a playlist: each song as a cover tile.
struct PlaylistArtGrid: View {
    @EnvironmentObject var model: AppModel
    let tracks: [CatalogTrack]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18, alignment: .top)],
                  alignment: .leading, spacing: 20) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                VStack(alignment: .leading, spacing: 2) {
                    CoverView(url: model.coverURL(t, size: 400))
                        .overlay(alignment: .topTrailing) { CoverSourceBadge(accountIDs: [t.accountID]) }
                        .onTapGesture(count: 2) { model.play(catalog: tracks, startAt: i) }
                    Text(t.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(t.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .contextMenu { SongsMenu(tracks: [t], context: tracks) }
            }
        }
    }
}

// MARK: - one library

/// A single source (sidebar « Library » rows): its own albums and songs,
/// not the merged view.
struct SourcePage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var catalog = CatalogStore.shared
    let accountID: String
    @State private var lib: CatalogStore.Built?
    @State private var loadedFor: String?
    @AppStorage("source.tab") private var tab = "albums"

    var body: some View {
        let name = model.accounts.first { $0.id == accountID }?.name ?? "Library"
        Group {
            if let lib, loadedFor == accountID {
                if tab == "songs" {
                    VStack(spacing: 0) {
                        PageTitle(text: name, subtitle: "\(lib.tracks.count) songs")
                        if lib.tracks.isEmpty {
                            EmptyState(text: catalog.syncing.contains(accountID) ? "Loading this library…" : "No songs")
                        } else {
                            SongsTable(tracks: lib.tracks, key: "source",
                                       defaultSort: [KeyPathComparator(\.title, comparator: .localizedStandard)])
                        }
                    }
                } else {
                    AlbumsPage(title: name, albums: lib.albums, modeKey: "source")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $tab) {
                    Text("Albums").tag("albums")
                    Text("Songs").tag("songs")
                }
                .pickerStyle(.segmented)
            }
        }
        .task(id: "\(accountID)|\(catalog.version)") {
            let b = await catalog.library(for: accountID)
            lib = b; loadedFor = accountID
        }
    }
}

// MARK: - recently played

/// Albums from the play history, most recent first, one tile per album.
/// A song played from outside the library (search result) gets a one-track
/// album of its own so it still shows up.
struct RecentlyPlayedPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var catalog = CatalogStore.shared
    @State private var albums: [CatalogAlbum] = []

    var body: some View {
        AlbumsPage(title: "Recently Played", albums: albums, modeKey: "played")
            .task(id: "\(model.historyVersion)|\(catalog.version)") {
                let byID = Dictionary(catalog.albums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                var seen = Set<String>(), out: [CatalogAlbum] = []
                for (date, m) in AppDatabase.shared.history(limit: 500) {
                    let t = CatalogTrack(meta: m, addedAt: date)
                    let key = t.albumKey
                    guard seen.insert(key).inserted else { continue }
                    out.append(byID[key] ?? CatalogAlbum(
                        id: key, title: t.album.isEmpty ? t.title : t.album, artist: t.artist,
                        year: t.year, genre: t.genre, addedAt: date, tracks: [t], accountIDs: [t.accountID]))
                    if out.count == 200 { break }
                }
                albums = out
            }
    }
}

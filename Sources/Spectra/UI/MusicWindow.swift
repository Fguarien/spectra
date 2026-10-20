import SwiftUI
import AVKit

/// The main window, laid out like Music.app: a sidebar (search, Library,
/// Playlists), the content area, the transport + « LCD » in the toolbar and
/// « Playing Next » as an inspector on the right.
struct MusicWindow: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("ui.showQueue") private var showQueue = false
    @State private var fullScreen = false

    var body: some View {
        NavigationSplitView {
            MusicSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            ContentRouter()
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $model.searchQuery, placement: .sidebar, prompt: "Search")
        .onSubmit(of: .search) { model.runSearch(model.searchQuery) }
        .onChange(of: model.searchQuery) { _, q in
            if q.isEmpty { model.searchHits = [] } else { model.scheduleSearch() }
        }
        .inspector(isPresented: $showQueue) {
            QueueView().inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) { TransportControls() }
            ToolbarItem(placement: .principal) { LCDView(fullScreen: $fullScreen) }
            ToolbarItemGroup(placement: .primaryAction) {
                VolumeControl()
                AirPlayButton().frame(width: 28, height: 22).help("AirPlay")
                Button { MiniPlayer.shared.toggle() } label: { Image(systemName: "pip") }
                    .help("Mini Player (⇧⌘M)")
                Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                    .help("Playing Next (⌥⌘U)")
                    .keyboardShortcut("u", modifiers: [.command, .option])
            }
        }
        .overlay {
            if fullScreen { FullScreenPlayer(isPresented: $fullScreen).transition(.opacity) }
        }
        .overlay(alignment: .bottomTrailing) { RadioToast().padding(16) }
        .animation(.easeInOut(duration: 0.2), value: fullScreen)
        .onReceive(NotificationCenter.default.publisher(for: .spectraFullScreenPlayer)) { _ in fullScreen.toggle() }
    }
}

extension Notification.Name {
    static let spectraFullScreenPlayer = Notification.Name("spectra.fullScreenPlayer")
}

// MARK: - sidebar

struct MusicSidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var catalog = CatalogStore.shared

    var body: some View {
        List(selection: Binding(get: { model.pane },
                                set: { model.pane = $0; model.openAlbum = nil; model.searchQuery = "" })) {
            Section("Library") {
                row(.recentlyAdded, "Recently Added", "clock")
                row(.artists, "Artists", "music.mic")
                row(.albums, "Albums", "square.stack")
                row(.songs, "Songs", "music.note")
                row(.genres, "Genres", "guitars")
                row(.downloads, "Downloaded", "arrow.down.circle")
            }
            Section("Playlists") {
                row(.loved, "Favourite Songs", "heart.fill")
                ForEach(model.localPlaylists) { pl in
                    Label(pl.name, systemImage: pl.kind == "radio" ? "dot.radiowaves.left.and.right" : "music.note.list")
                        .tag(AppModel.Pane.localPlaylist(pl.id))
                        .contextMenu {
                            Button("Play") { model.play(model.localPlaylistTracks(pl), startAt: 0) }
                            Button("Download Playlist") { model.downloadAll(model.localPlaylistTracks(pl)) }
                            Button("Rename…") { model.renameLocalPlaylist(pl) }
                            Divider()
                            Button("Delete Playlist", role: .destructive) { model.deleteLocalPlaylist(pl) }
                        }
                }
                ForEach(model.allPlaylists) { pl in
                    Label {
                        Text(pl.title)
                    } icon: {
                        Image(systemName: "music.note.list")
                    }
                    .overlay(alignment: .trailing) { SourceIcon(accountID: pl.sourceAccountID) }
                    .tag(AppModel.Pane.playlist(pl))
                    .contextMenu {
                        Button("Play") { Task { model.play(await model.playlistTracks(pl), startAt: 0) } }
                        Button("Download Playlist") {
                            Task { model.downloadAll(await model.playlistTracks(pl), collection: pl) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { syncFooter }
    }

    private func row(_ pane: AppModel.Pane, _ label: String, _ icon: String) -> some View {
        Label(label, systemImage: icon).tag(pane)
    }

    @ViewBuilder private var syncFooter: some View {
        if !catalog.syncing.isEmpty {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Updating library…").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
    }
}

/// Tiny provider glyph (Plex / folder / YouTube) for a row's account.
struct SourceIcon: View {
    @EnvironmentObject var model: AppModel
    let accountID: String?

    var body: some View {
        if let acc = model.accounts.first(where: { $0.id == accountID }) {
            Image(systemName: acc.kind.systemImage)
                .font(.caption2).foregroundStyle(.tertiary)
                .help(acc.name)
        }
    }
}

// MARK: - routing

struct ContentRouter: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var catalog = CatalogStore.shared

    var body: some View {
        Group {
            // Like Music.app: typing in the sidebar field shows the results
            // over whatever page is open; clearing it brings the page back.
            if !model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchView()
            } else if let album = model.openAlbum {
                AlbumDetailView(album: album)
            } else {
                switch model.pane {
                case .recentlyAdded:
                    AlbumsPage(title: "Recently Added", albums: recent, modeKey: "recent")
                case .albums:
                    AlbumsPage(title: "Albums", albums: catalog.albums, modeKey: "albums")
                case .songs:
                    SongsPage()
                case .artists:
                    ArtistsPage()
                case .genres:
                    GenresPage()
                case .downloads:
                    DownloadsView()
                case .search:
                    SearchView()
                case .loved:
                    PlaylistPage(source: .loved)
                case .playlist(let pl):
                    PlaylistPage(source: .remote(pl))
                case .localPlaylist(let id):
                    if let pl = model.localPlaylists.first(where: { $0.id == id }) {
                        PlaylistPage(source: .local(pl))
                    } else {
                        EmptyState(text: "Playlist not found")
                    }
                }
            }
        }
        .toolbar {
            if model.openAlbum != nil {
                ToolbarItem(placement: .navigation) {
                    Button { model.openAlbum = nil } label: { Image(systemName: "chevron.left") }
                        .help("Back")
                        .keyboardShortcut("[", modifiers: .command)
                }
            }
        }
    }

    private var recent: [CatalogAlbum] {
        Array(catalog.albums.sorted { $0.addedAt > $1.addedAt }.prefix(400))
    }
}

struct EmptyState: View {
    let text: String
    var body: some View {
        Text(text).font(.title3).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - toolbar: transport

struct TransportControls: View {
    @ObservedObject private var player = AudioPlayer.shared

    var body: some View {
        HStack(spacing: 2) {
            Button { player.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help("Shuffle")
            Button { player.previous() } label: { Image(systemName: "backward.fill") }.help("Previous")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    .frame(width: 26)
            }
            .help(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill") }.help("Next")
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help("Repeat")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
    }
}

struct VolumeControl: View {
    @ObservedObject private var player = AudioPlayer.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                .controlSize(.mini)
                .frame(width: 90)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
        .help("Volume")
    }
}

/// System AirPlay / output picker, as in Music's toolbar.
struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

// MARK: - toolbar: LCD

/// Music's centre « LCD »: cover, title, artist — album, and a thin progress
/// bar that shows the times and seeks on hover.
struct LCDView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    @Binding var fullScreen: Bool
    @State private var hover = false
    @State private var dragValue: Double?

    var body: some View {
        HStack(spacing: 0) {
            ArtworkView(url: player.current?.artworkURL, side: 38)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .onTapGesture { if player.current != nil { fullScreen = true } }
                .help("Full Screen Player")
            ZStack {
                if let t = player.current {
                    VStack(spacing: 1) {
                        Text(t.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text([t.artist, t.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 54)
                    .padding(.bottom, 6)
                } else {
                    Image(systemName: "music.note").font(.title3).foregroundStyle(.tertiary)
                }
                if hover, player.current != nil {
                    HStack {
                        Text(time(dragValue ?? player.currentTime)).font(.system(size: 10).monospacedDigit())
                        Spacer()
                        HeartButton(font: .system(size: 12))
                        Text("-" + time(max(player.duration - (dragValue ?? player.currentTime), 0)))
                            .font(.system(size: 10).monospacedDigit())
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { progress }
        }
        .frame(minWidth: 360, idealWidth: 520, maxWidth: 640)
        .frame(height: 38)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hover = $0 }
    }

    private var progress: some View {
        GeometryReader { geo in
            let d = max(player.duration, 1)
            let f = min(max((dragValue ?? player.currentTime) / d, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(hover ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: geo.size.width * f)
            }
            .frame(height: hover ? 4 : 2)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragValue = min(max(v.location.x / geo.size.width, 0), 1) * d }
                .onEnded { _ in
                    if let v = dragValue { player.seek(to: v) }
                    dragValue = nil
                })
        }
        .frame(height: 10)
        .opacity(player.current == nil ? 0 : 1)
    }

    private func time(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - full screen player

/// Music's full-screen player: the cover large over a blurred copy of itself.
struct FullScreenPlayer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            ArtworkView(url: player.current?.largeArtworkURL ?? player.current?.artworkURL, side: 1400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: 80)
                .overlay(Color.black.opacity(0.45))
                .clipped()
            NowPlayingView()
                .environment(\.colorScheme, .dark)
                .foregroundStyle(.white)
        }
        .overlay(alignment: .topLeading) {
            Button { isPresented = false } label: {
                Image(systemName: "chevron.down.circle.fill").font(.title)
            }
            .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.8))
            .keyboardShortcut(.escape, modifiers: [])
            .padding(16)
        }
        .ignoresSafeArea()
    }
}

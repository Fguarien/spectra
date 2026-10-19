import SwiftUI

/// Three-column music browser: artists → albums → tracks, with a toolbar
/// that exposes server name, sign-out and the Prism importer.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedArtist: PlexMetadata?
    @State private var albums: [PlexMetadata] = []
    @State private var selectedAlbum: PlexMetadata?
    @State private var tracks: [PlexMetadata] = []

    var body: some View {
        NavigationSplitView {
            artistColumn
        } content: {
            albumColumn
        } detail: {
            TrackListView(album: selectedAlbum, tracks: tracks)
        }
        .toolbar { toolbarContent }
        .onChange(of: selectedArtist) { _, artist in loadAlbums(artist) }
        .onChange(of: selectedAlbum) { _, album in loadTracks(album) }
    }

    private var artistColumn: some View {
        List(model.artists, id: \.ratingKey, selection: $selectedArtist) { artist in
            Text(artist.title).tag(Optional(artist))
        }
        .navigationTitle("Artists")
    }

    private var albumColumn: some View {
        List(albums, id: \.ratingKey, selection: $selectedAlbum) { album in
            AlbumRow(album: album, imageURL: model.imageURL(album.thumb, size: 80))
                .tag(Optional(album))
        }
        .navigationTitle(selectedArtist?.title ?? "Albums")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Label(model.serverName, systemImage: "server.rack")
        }
        ToolbarItemGroup {
            if let msg = model.importMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            Button("Import from Prism…") { pickPrismDB() }
            Button("Sign out") { model.signOut() }
        }
    }

    private func loadAlbums(_ artist: PlexMetadata?) {
        guard let artist else { albums = []; return }
        Task { albums = await model.albums(of: artist) }
    }

    private func loadTracks(_ album: PlexMetadata?) {
        guard let album else { tracks = []; return }
        Task { tracks = await model.tracks(of: album) }
    }

    private func pickPrismDB() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Prism Items.db exported from the .imazingapp"
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            model.runImport(prismDBPath: url.path)
        }
    }
}

struct AlbumRow: View {
    let album: PlexMetadata
    let imageURL: URL?

    var body: some View {
        HStack {
            ArtworkView(url: imageURL, side: 40)
            VStack(alignment: .leading) {
                Text(album.title)
                if let year = album.year {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct TrackListView: View {
    @EnvironmentObject var model: AppModel
    let album: PlexMetadata?
    let tracks: [PlexMetadata]

    var body: some View {
        if let album {
            List(Array(tracks.enumerated()), id: \.element.ratingKey) { pair in
                TrackRow(index: pair.offset, track: pair.element)
                    .contentShape(Rectangle())
                    .onTapGesture { playFrom(index: pair.offset) }
            }
            .navigationTitle(album.title)
        } else {
            Text("Select an album").foregroundStyle(.secondary)
        }
    }

    private func playFrom(index: Int) {
        let artist = album?.parentTitle ?? ""
        let albumTitle = album?.title ?? ""
        let playables = tracks.compactMap { model.playable($0, albumTitle: albumTitle, artist: artist) }
        guard !playables.isEmpty else { return }
        AudioPlayer.shared.play(tracks: playables, startAt: min(index, playables.count - 1))
    }
}

struct TrackRow: View {
    let index: Int
    let track: PlexMetadata

    var body: some View {
        HStack {
            Text(track.index.map(String.init) ?? "\(index + 1)")
                .frame(width: 28, alignment: .trailing).foregroundStyle(.secondary)
            Text(track.title)
            Spacer()
            Text(durationText(track.duration)).foregroundStyle(.secondary).font(.callout)
        }
    }

    private func durationText(_ ms: Int?) -> String {
        guard let ms else { return "" }
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct ArtworkView: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "music.note"))
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

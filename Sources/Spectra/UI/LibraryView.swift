import SwiftUI

/// Three-column music browser: artists → albums (+ similar artists) → tracks.
/// Selection is driven by explicit taps (not `List(selection:)`, which is
/// unreliable inside the app's custom pane layout), with manual row highlight.
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
            middleColumn
        } detail: {
            TrackListView(album: selectedAlbum, tracks: tracks)
        }
        .onChange(of: selectedArtist) { _, artist in loadAlbums(artist) }
        .onChange(of: selectedAlbum) { _, album in loadTracks(album) }
    }

    private var artistColumn: some View {
        List {
            ForEach(model.artists) { artist in
                Text(artist.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedArtist = artist }
                    .listRowBackground(selectedArtist == artist ? Color.accentColor.opacity(0.22) : Color.clear)
            }
        }
        .navigationTitle("Artists")
    }

    private var middleColumn: some View {
        List {
            Section("Albums") {
                ForEach(albums) { album in
                    AlbumRow(album: album, imageURL: model.imageURL(for: album, size: 80))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedAlbum = album }
                        .listRowBackground(selectedAlbum == album ? Color.accentColor.opacity(0.22) : Color.clear)
                }
                if albums.isEmpty { Text(selectedArtist == nil ? "Select an artist" : "No albums").foregroundStyle(.secondary) }
            }
            if !model.similarArtists.isEmpty {
                Section("Similar Artists") {
                    ForEach(model.similarArtists) { a in
                        Text(a.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedArtist = a }
                    }
                }
            }
        }
        .navigationTitle(selectedArtist?.title ?? "Albums")
    }

    private func loadAlbums(_ artist: PlexMetadata?) {
        selectedAlbum = nil; tracks = []
        guard let artist else { albums = []; model.similarArtists = []; return }
        model.loadSimilar(for: artist)
        Task { albums = await model.albums(of: artist) }
    }

    private func loadTracks(_ album: PlexMetadata?) {
        guard let album else { tracks = []; return }
        Task { tracks = await model.tracks(of: album) }
    }
}

struct AlbumRow: View {
    let album: PlexMetadata
    var imageURL: URL? = nil      // retained for callers; AlbumArtwork handles the fallback

    var body: some View {
        HStack {
            AlbumArtwork(item: album, side: 40)
            VStack(alignment: .leading) {
                Text(album.title)
                if let year = album.year {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            CollectionBadge(collection: album)
        }
    }
}

struct TrackListView: View {
    @EnvironmentObject var model: AppModel
    let album: PlexMetadata?
    let tracks: [PlexMetadata]

    var body: some View {
        if let album {
            VStack(spacing: 0) {
                header(album)
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { pair in
                        TrackRow(index: pair.offset, track: pair.element,
                                 albumTitle: album.title, artist: album.parentTitle ?? "")
                            .contentShape(Rectangle())
                            .onTapGesture { playFrom(index: pair.offset, album: album) }
                            .contextMenu {
                                TrackMenu(track: pair.element, albumTitle: album.title,
                                          artist: album.parentTitle ?? "")
                            }
                    }
                }
            }
            .navigationTitle(album.title)
        } else {
            Text("Select an album").foregroundStyle(.secondary)
        }
    }

    private func header(_ album: PlexMetadata) -> some View {
        HStack(spacing: 14) {
            AlbumArtwork(item: album, side: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title).font(.title3).fontWeight(.semibold)
                Text(album.parentTitle ?? "").foregroundStyle(.secondary)
                HStack {
                    Button {
                        playFrom(index: 0, album: album)
                    } label: { Label("Play", systemImage: "play.fill") }
                    Button { model.downloadAll(tracks, collection: album) } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(tracks.isEmpty)
                    .help("Download the whole album to the NAS")
                    CollectionBadge(trackKeys: tracks.map(\.ratingKey))
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func playFrom(index: Int, album: PlexMetadata) {
        model.play(tracks, startAt: index, albumTitle: album.title, artist: album.parentTitle ?? "")
    }
}

struct TrackRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    let track: PlexMetadata
    let albumTitle: String
    let artist: String

    var body: some View {
        HStack(spacing: 10) {
            Text(track.index.map(String.init) ?? "\(index + 1)")
                .frame(width: 26, alignment: .trailing).foregroundStyle(.secondary)
            Text(track.title).lineLimit(1)
            Spacer()
            OfflineBadge(ratingKey: track.ratingKey)
            StarRatingView(rating: currentRating, compact: true) { model.rate(track, stars: $0) }
            Text(durationText(track.duration)).foregroundStyle(.secondary).font(.callout)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var currentRating: Int {
        model.rating(track.ratingKey) ?? track.userRating.map { Int($0 / 2) } ?? 0
    }
}

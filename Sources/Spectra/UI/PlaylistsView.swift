import SwiftUI

/// Live Plex playlists (browse, play, delete) plus playlists imported from
/// Prism that can be recreated on the server.
struct PlaylistsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: PlexMetadata?
    @State private var tracks: [PlexMetadata] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selected) {
                Section("Plex Playlists") {
                    ForEach(model.playlists) { pl in
                        Label {
                            VStack(alignment: .leading) {
                                Text(pl.title)
                                if let n = pl.leafCount { Text("\(n) tracks").font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: { Image(systemName: "music.note.list") }
                        .tag(Optional(pl))
                    }
                    if model.playlists.isEmpty { Text("None").foregroundStyle(.secondary) }
                }
                let imported = model.importedPrismPlaylists()
                if !imported.isEmpty {
                    Section("Imported from Prism") {
                        ForEach(imported, id: \.self) { name in
                            HStack {
                                Text(name)
                                Spacer()
                                Button("Recreate on Plex") { model.recreatePrismPlaylist(named: name) }
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playlists")
        } detail: {
            detail
        }
        .onChange(of: selected) { _, pl in load(pl) }
    }

    @ViewBuilder private var detail: some View {
        if let pl = selected {
            VStack(spacing: 0) {
                HStack {
                    Text(pl.title).font(.title2).fontWeight(.semibold)
                    Spacer()
                    Button { model.play(tracks, startAt: 0) } label: { Label("Play", systemImage: "play.fill") }
                    Button(role: .destructive) {
                        model.deletePlaylist(pl); selected = nil; tracks = []
                    } label: { Label("Delete", systemImage: "trash") }
                }
                .padding(16)
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { pair in
                        TrackRow(index: pair.offset, track: pair.element,
                                 albumTitle: pair.element.parentTitle ?? "",
                                 artist: pair.element.grandparentTitle ?? "")
                            .contentShape(Rectangle())
                            .onTapGesture { model.play(tracks, startAt: pair.offset) }
                            .contextMenu {
                                TrackMenu(track: pair.element, albumTitle: pair.element.parentTitle ?? "",
                                          artist: pair.element.grandparentTitle ?? "")
                            }
                    }
                }
            }
        } else {
            Text("Select a playlist").foregroundStyle(.secondary)
        }
    }

    private func load(_ pl: PlexMetadata?) {
        guard let pl else { tracks = []; return }
        Task { tracks = await model.playlistTracks(pl) }
    }
}

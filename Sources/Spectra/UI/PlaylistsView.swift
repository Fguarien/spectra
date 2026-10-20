import SwiftUI

/// Live Plex playlists (browse, play, delete) plus playlists imported from
/// Prism that can be recreated on the server. Selection is tap-driven with a
/// manual highlight (not `List(selection:)`).
struct PlaylistsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: PlexMetadata?
    @State private var selectedLocal: LocalPlaylist?
    @State private var tracks: [PlexMetadata] = []

    var body: some View {
        NavigationSplitView {
            List {
                Section("Spectra") {
                    ForEach(model.localPlaylists) { pl in
                        Label {
                            VStack(alignment: .leading) {
                                Text(pl.name)
                                Text("\(pl.count) tracks · all sources").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: pl.kind == "radio" ? "heart.circle" : "music.note.list") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) {
                            CollectionBadge(trackKeys: model.localPlaylistTracks(pl).map(\.ratingKey))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selected = nil; selectedLocal = pl; loadLocal(pl) }
                        .selectedRow(selectedLocal?.id == pl.id)
                    }
                    if model.localPlaylists.isEmpty {
                        Text("Love a track (♥) to start a radio").foregroundStyle(.secondary)
                    }
                }
                Section("\(model.serverName.isEmpty ? "Account" : model.serverName) Playlists") {
                    ForEach(model.playlists) { pl in
                        Label {
                            VStack(alignment: .leading) {
                                Text(pl.title)
                                if let n = pl.leafCount { Text("\(n) tracks").font(.caption).foregroundStyle(.secondary) }
                            }
                        } icon: { Image(systemName: "music.note.list") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) { CollectionBadge(collection: pl) }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedLocal = nil; selected = pl }
                        .selectedRow(selected == pl)
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
        if let pl = selectedLocal {
            VStack(spacing: 0) {
                HStack {
                    Text(pl.name).font(.title2).fontWeight(.semibold)
                    CollectionBadge(trackKeys: tracks.map(\.ratingKey))
                    Spacer()
                    Button { model.play(tracks, startAt: 0) } label: { Label("Play", systemImage: "play.fill") }
                        .disabled(tracks.isEmpty)
                    Button { model.downloadAll(tracks) } label: { Label("Download", systemImage: "arrow.down.circle") }
                        .disabled(tracks.isEmpty)
                    Button(role: .destructive) {
                        model.deleteLocalPlaylist(pl); selectedLocal = nil; tracks = []
                    } label: { Label("Delete", systemImage: "trash") }
                }
                .padding(16)
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { pair in
                        HStack {
                            TrackRow(index: pair.offset, track: pair.element,
                                     albumTitle: pair.element.parentTitle ?? "",
                                     artist: pair.element.grandparentTitle ?? "")
                            Text(pair.element.grandparentTitle ?? "").font(.caption).foregroundStyle(.secondary)
                            SourceBadges(rows: [pair.element])
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.play(tracks, startAt: pair.offset) }
                        .contextMenu {
                            TrackMenu(track: pair.element, albumTitle: pair.element.parentTitle ?? "",
                                      artist: pair.element.grandparentTitle ?? "")
                            Divider()
                            Button("Remove from \(pl.name)") {
                                model.removeFromLocalPlaylist(pl, pair.element); loadLocal(pl)
                            }
                        }
                    }
                }
            }
        } else if let pl = selected {
            VStack(spacing: 0) {
                HStack {
                    Text(pl.title).font(.title2).fontWeight(.semibold)
                    CollectionBadge(trackKeys: tracks.map(\.ratingKey))
                    Spacer()
                    Button { model.play(tracks, startAt: 0) } label: { Label("Play", systemImage: "play.fill") }
                        .disabled(tracks.isEmpty)
                    Button { model.downloadAll(tracks, collection: pl) } label: { Label("Download", systemImage: "arrow.down.circle") }
                        .disabled(tracks.isEmpty)
                        .help("Download every track to the NAS")
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

    private func loadLocal(_ pl: LocalPlaylist) {
        tracks = model.localPlaylistTracks(pl)
    }

    private func load(_ pl: PlexMetadata?) {
        guard let pl else { if selectedLocal == nil { tracks = [] }; return }
        Task { tracks = await model.playlistTracks(pl) }
    }
}

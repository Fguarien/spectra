import SwiftUI

/// Server-side search across the music library (`/hubs/search`), grouped by
/// result type. Track rows play directly; artist and album rows drill down
/// (artist → albums → tracks, album → tracks) so every result is reachable.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if model.searchHits.isEmpty {
                    Spacer()
                    Text("Type a query and press return").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(Array(model.searchHits.enumerated()), id: \.offset) { _, hub in
                            Section(hub.title ?? (hub.type ?? "Results").capitalized) {
                                ForEach(hub.items) { item in
                                    hubRow(item, type: hub.type ?? "")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search artists, albums, tracks…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { model.runSearch(query) }
            if !query.isEmpty {
                Button { query = ""; model.searchHits = [] } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(16)
    }

    @ViewBuilder private func hubRow(_ item: PlexMetadata, type: String) -> some View {
        if type == "track" {
            HStack {
                Text(item.title)
                Text("— \(item.grandparentTitle ?? "")").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text(durationText(item.duration)).foregroundStyle(.secondary).font(.callout)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.play([item], startAt: 0,
                                       albumTitle: item.parentTitle ?? "", artist: item.grandparentTitle ?? "") }
            .contextMenu { TrackMenu(track: item, albumTitle: item.parentTitle ?? "", artist: item.grandparentTitle ?? "") }
        } else {
            NavigationLink {
                SearchDrillView(item: item, kind: type == "artist" ? "artist" : "album")
            } label: {
                HStack {
                    ArtworkView(url: model.imageURL(item.thumb, size: 60), side: 32)
                    Text(item.title)
                    if let sub = item.parentTitle ?? item.grandparentTitle {
                        Text("— \(sub)").foregroundStyle(.secondary).font(.caption)
                    }
                }
            }
        }
    }
}

/// Drill-down from a search result: an artist shows its albums (each drilling
/// further into its tracks); an album shows its tracks, tappable to play.
struct SearchDrillView: View {
    @EnvironmentObject var model: AppModel
    let item: PlexMetadata
    let kind: String            // "artist" or "album"
    @State private var children: [PlexMetadata] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.large)
            } else if kind == "artist" {
                List {
                    Section("Albums") {
                        ForEach(children) { album in
                            NavigationLink {
                                SearchDrillView(item: album, kind: "album")
                            } label: {
                                AlbumRow(album: album, imageURL: model.imageURL(album.thumb, size: 80))
                            }
                        }
                    }
                }
            } else {
                List {
                    Section {
                        Button {
                            model.play(children, startAt: 0,
                                       albumTitle: item.title, artist: item.parentTitle ?? "")
                        } label: { Label("Play", systemImage: "play.fill") }
                    }
                    ForEach(Array(children.enumerated()), id: \.element.ratingKey) { pair in
                        TrackRow(index: pair.offset, track: pair.element,
                                 albumTitle: item.title, artist: item.parentTitle ?? "")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.play(children, startAt: pair.offset,
                                           albumTitle: item.title, artist: item.parentTitle ?? "")
                            }
                            .contextMenu {
                                TrackMenu(track: pair.element, albumTitle: item.title,
                                          artist: item.parentTitle ?? "")
                            }
                    }
                }
            }
        }
        .navigationTitle(item.title)
        .task { await load() }
    }

    private func load() async {
        children = kind == "artist" ? await model.albums(of: item) : await model.tracks(of: item)
        loading = false
    }
}

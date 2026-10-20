import SwiftUI

/// Search across EVERY connected account (Plex, Local Files, YouTube Music),
/// driven by the toolbar field. Results are grouped by provider, then by type.
/// Track rows play directly; artist and album rows drill down (artist →
/// albums → tracks, album → tracks), each served by the account it came from.
struct SearchView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            Group {
                if model.searchHits.isEmpty {
                    VStack(spacing: 8) {
                        if model.searching {
                            ProgressView()
                        } else {
                            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text(model.searchQuery.isEmpty ? "Search all your sources from the toolbar"
                                                           : "No results")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.searchHits) { section in
                            Section {
                                ForEach(section.items) { item in
                                    hubRow(item, type: section.type)
                                }
                            } header: {
                                Label("\(section.account.name) — \(section.title)",
                                      systemImage: section.account.kind.systemImage)
                            }
                        }
                    }
                }
            }
        }
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
                    ArtworkView(url: model.imageURL(for: item, size: 60), side: 32)
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
                                AlbumRow(album: album, imageURL: model.imageURL(for: album, size: 80))
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

import SwiftUI

/// Search across EVERY connected account (Plex, Local Files, YouTube Music),
/// driven by the toolbar field. Results are grouped by source — the same song
/// found in Plex and on YouTube Music shows under both, so you pick the version
/// to play. Each source lists its library matches first (instant, offline-safe,
/// every copy), then what its own search answered. Track rows play directly;
/// artist and album rows drill down, served by the account they came from.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared

    var body: some View {
        content
            // Computed once per query (not per redraw: the player ticks every second).
            .task(id: model.searchQuery) {
                (libraryAlbums, librarySongs) = CatalogStore.shared.search(model.searchQuery)
            }
    }

    /// One block per account that has something, in sidebar order.
    private struct SourceBlock: Identifiable {
        let account: Account
        let songs: [CatalogTrack]
        let hubs: [SearchSection]
        var id: String { account.id }
    }

    private var blocks: [SourceBlock] {
        model.accounts.compactMap { acc in
            let songs = librarySongs[acc.id] ?? []
            let shown = Set(songs.map(\.ratingKey))
            // A track already listed from the library is not repeated from the live search.
            let hubs: [SearchSection] = model.searchHits.filter { $0.account.id == acc.id }.compactMap { sec in
                guard sec.type == "track" else { return sec }
                let rest = sec.items.filter { !shown.contains($0.ratingKey) }
                return rest.isEmpty ? nil : SearchSection(account: sec.account, title: sec.title,
                                                          type: sec.type, items: rest)
            }
            return songs.isEmpty && hubs.isEmpty ? nil : SourceBlock(account: acc, songs: songs, hubs: hubs)
        }
    }

    private var content: some View {
        let all = blocks
        let visible = all.filter { sourceFilter == nil || $0.id == sourceFilter }
        let albums = libraryAlbums.filter { a in sourceFilter.map { a.accountIDs.contains($0) } ?? true }
        return NavigationStack {
            Group {
                if all.isEmpty && libraryAlbums.isEmpty {
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
                        if all.count > 1 {
                            Picker("Source", selection: $sourceFilter) {
                                Text("All Sources").tag(String?.none)
                                ForEach(all) { b in
                                    Label(b.account.name, systemImage: b.account.kind.systemImage)
                                        .tag(String?.some(b.id))
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .padding(.vertical, 4)
                        }
                        if !albums.isEmpty {
                            Section("Albums in Your Library") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(alignment: .top, spacing: 16) {
                                        ForEach(albums) { AlbumCell(album: $0).frame(width: 140) }
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                        ForEach(visible) { block in
                            Section {
                                ForEach(Array(block.songs.enumerated()), id: \.element.id) { i, t in
                                    songRow(t)
                                        .onTapGesture { model.play(catalog: block.songs, startAt: i) }
                                        .contextMenu { SongsMenu(tracks: [t], context: block.songs) }
                                }
                                ForEach(block.hubs) { section in
                                    if block.songs.isEmpty && block.hubs.count == 1 && section.type == "track" {
                                        EmptyView()
                                    } else {
                                        Text(section.title).font(.caption).foregroundStyle(.secondary)
                                            .padding(.top, 4)
                                    }
                                    ForEach(section.items) { item in
                                        hubRow(item, type: section.type)
                                    }
                                }
                            } header: {
                                HStack {
                                    Label(block.account.name, systemImage: block.account.kind.systemImage)
                                    if model.searching && !model.searchHits.contains(where: { $0.account.id == block.id }) {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                        }
                        if model.searching {
                            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        }
                    }
                }
            }
        }
        // A source picked for one query means nothing for the next.
        .onChange(of: model.searchQuery) { _, _ in sourceFilter = nil }
    }

    // Matches in the library: albums (merged) and songs per account (every copy).
    @State private var libraryAlbums: [CatalogAlbum] = []
    @State private var librarySongs: [String: [CatalogTrack]] = [:]
    @State private var sourceFilter: String?

    private func songRow(_ t: CatalogTrack) -> some View {
        let playing = player.current?.id == t.ratingKey
        return HStack {
            if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
            Text(t.title).lineLimit(1)
            Text("— \(t.artist)\(t.album.isEmpty ? "" : " · \(t.album)")")
                .foregroundStyle(.secondary).font(.caption).lineLimit(1)
            Spacer()
            OfflineBadge(ratingKey: t.ratingKey)
            if model.isLiked(t.meta) { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink) }
            Text(formatDuration(ms: t.durationMs)).foregroundStyle(.secondary).font(.callout).monospacedDigit()
        }
        .selectedRow(playing)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func hubRow(_ item: PlexMetadata, type: String) -> some View {
        if type == "track" {
            HStack {
                if AudioPlayer.shared.current?.id == item.ratingKey {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                }
                Text(item.title)
                Text("— \(item.grandparentTitle ?? "")").foregroundStyle(.secondary).font(.caption)
                Spacer()
                OfflineBadge(ratingKey: item.ratingKey)
                Text(durationText(item.duration)).foregroundStyle(.secondary).font(.callout)
            }
            .selectedRow(player.current?.id == item.ratingKey)
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

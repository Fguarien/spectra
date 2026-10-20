import SwiftUI

/// Every account's artists in one list, merged by normalised name (Local +
/// YouTube Music + Plex). Selecting an artist loads its albums from each
/// account that has it, badged by provider; tracks play from their own source.
struct AllSourcesView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: MergedArtist?
    @State private var albums: [PlexMetadata] = []
    @State private var loadingAlbums = false
    @State private var selectedAlbum: PlexMetadata?
    @State private var tracks: [PlexMetadata] = []
    @State private var filter = ""

    var body: some View {
        NavigationSplitView {
            artistColumn
        } content: {
            albumColumn
        } detail: {
            TrackListView(album: selectedAlbum, tracks: tracks)
        }
        .onChange(of: selected) { _, a in loadAlbums(a) }
        .onChange(of: selectedAlbum) { _, a in loadTracks(a) }
    }

    private var visibleArtists: [MergedArtist] {
        let f = MergedArtist.normalise(filter)
        guard !f.isEmpty else { return model.mergedArtists }
        return model.mergedArtists.filter { $0.key.contains(f) }
    }

    private var artistColumn: some View {
        List {
            if !model.poolStatus.isEmpty {
                Section("Unavailable") {
                    ForEach(model.accounts.filter { model.poolStatus[$0.id] != nil }) { acc in
                        Label(acc.name, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .help(model.poolStatus[acc.id] ?? "")
                    }
                }
            }
            ForEach(visibleArtists) { artist in
                HStack {
                    Text(artist.name).lineLimit(1)
                    Spacer()
                    SourceBadges(rows: artist.members)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { selected = artist }
                .listRowBackground(selected == artist ? Color.accentColor.opacity(0.22) : Color.clear)
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter artists")
        .navigationTitle("All Sources (\(model.mergedArtists.count))")
    }

    private var albumColumn: some View {
        List {
            Section("Albums") {
                ForEach(albums) { album in
                    HStack {
                        AlbumRow(album: album)
                        Spacer()
                        SourceBadges(rows: [album])
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedAlbum = album }
                    .listRowBackground(selectedAlbum == album ? Color.accentColor.opacity(0.22) : Color.clear)
                }
                if loadingAlbums {
                    ProgressView()
                } else if albums.isEmpty {
                    Text(selected == nil ? "Select an artist" : "No albums").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(selected?.name ?? "Albums")
    }

    private func loadAlbums(_ artist: MergedArtist?) {
        selectedAlbum = nil; tracks = []; albums = []
        guard let artist else { return }
        loadingAlbums = true
        Task {
            var out: [PlexMetadata] = []
            await withTaskGroup(of: [PlexMetadata].self) { group in
                for member in artist.members {
                    group.addTask { await model.albums(of: member) }
                }
                for await list in group { out.append(contentsOf: list) }
            }
            guard selected == artist else { return }
            // Keep account order stable (as configured), then by year/title.
            let order = model.accounts.map(\.id)
            albums = out.sorted {
                let a = order.firstIndex(of: $0.sourceAccountID ?? "") ?? 0
                let b = order.firstIndex(of: $1.sourceAccountID ?? "") ?? 0
                if a != b { return a < b }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            loadingAlbums = false
        }
    }

    private func loadTracks(_ album: PlexMetadata?) {
        tracks = []
        guard let album else { return }
        Task {
            let t = await model.tracks(of: album)
            if selectedAlbum == album { tracks = t }
        }
    }
}

/// Small provider icons for the accounts a row (or merged artist) comes from.
struct SourceBadges: View {
    @EnvironmentObject var model: AppModel
    let rows: [PlexMetadata]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(accounts) { acc in
                Image(systemName: acc.kind.systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(acc.name)
            }
        }
    }

    private var accounts: [Account] {
        var seen = Set<String>()
        return rows.compactMap { model.account(for: $0) }.filter { seen.insert($0.id).inserted }
    }
}

import SwiftUI

/// Server-side search across the music library (`/hubs/search`), grouped by
/// result type. Tracks are directly playable.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
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
            HStack {
                ArtworkView(url: model.imageURL(item.thumb, size: 60), side: 32)
                Text(item.title)
                if let sub = item.parentTitle { Text("— \(sub)").foregroundStyle(.secondary).font(.caption) }
            }
        }
    }
}

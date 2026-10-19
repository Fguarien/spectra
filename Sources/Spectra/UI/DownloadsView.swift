import SwiftUI

/// Tracks available offline. Plays straight from local files, so it works even
/// when the Plex server is unreachable.
struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var records: [TrackRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(.title2).fontWeight(.semibold)
                Spacer()
                if !records.isEmpty {
                    Button { model.playDownloaded(records, startAt: 0) } label: { Label("Play All", systemImage: "play.fill") }
                }
            }
            .padding(16)

            if records.isEmpty {
                Spacer()
                Text("No downloaded tracks.\nUse “Download for Offline” from a track’s menu.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(Array(records.enumerated()), id: \.element.id) { pair in
                        HStack {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(pair.element.trackTitle ?? "Unknown")
                                Text("\(pair.element.artistName ?? "") — \(pair.element.albumTitle ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(durationText(pair.element.durationMs)).foregroundStyle(.secondary).font(.callout)
                            Button(role: .destructive) {
                                if let k = pair.element.ratingKey { downloads.removeDownload(ratingKey: k) }
                                reload()
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.playDownloaded(records, startAt: pair.offset) }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: downloads.downloaded) { _, _ in reload() }
    }

    private func reload() { records = model.downloadedTracks() }
}

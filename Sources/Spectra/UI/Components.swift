import SwiftUI

/// Five-star rating control. Tapping the current value clears it (→ 0).
struct StarRatingView: View {
    let rating: Int           // 0…5
    var compact: Bool = false
    let onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .foregroundStyle(i <= rating ? AnyShapeStyle(.yellow) : AnyShapeStyle(.secondary))
                    .font(compact ? .caption2 : .body)
                    .onTapGesture { onRate(i == rating ? 0 : i) }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Square artwork with a music-note placeholder.
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

/// Album artwork that prefers the embedded/folder/server image and, when a local
/// album has none, fetches a square cover from the web (iTunes) once, lazily.
struct AlbumArtwork: View {
    @EnvironmentObject var model: AppModel
    let item: PlexMetadata
    let side: CGFloat
    @State private var remote: URL?

    private var localURL: URL? { model.imageURL(for: item, size: Int(side * 3)) }

    var body: some View {
        ArtworkView(url: localURL ?? remote, side: side)
            .task(id: item.ratingKey) {
                guard localURL == nil, remote == nil else { return }
                remote = await model.remoteCover(for: item)
            }
    }
}

/// Right-click actions shared by every track row: play next, queue, rate,
/// add to a playlist, download / remove download.
struct TrackMenu: View {
    @EnvironmentObject var model: AppModel
    let track: PlexMetadata
    let albumTitle: String
    let artist: String

    var body: some View {
        Button("Play") { model.play([track], startAt: 0, albumTitle: albumTitle, artist: artist) }
        Button(model.isLiked(track) ? "Unlove ♥" : "Love ♥") { model.toggleLike(track) }
        Button("Play Next") { model.enqueue(track, albumTitle: albumTitle, artist: artist, playNext: true) }
        Button("Add to Queue") { model.enqueue(track, albumTitle: albumTitle, artist: artist, playNext: false) }
        Divider()
        Menu("Rate") {
            ForEach(0...5, id: \.self) { n in
                Button(n == 0 ? "No rating" : String(repeating: "★", count: n)) { model.rate(track, stars: n) }
            }
        }
        Menu("Add to Playlist") {
            ForEach(model.playlists) { pl in
                Button(pl.title) { model.addToPlaylist(pl, tracks: [track]) }
            }
            if model.playlists.isEmpty { Text("No playlists").disabled(true) }
        }
        Divider()
        if DownloadManager.shared.isDownloaded(track.ratingKey) {
            Button("Remove Download") { DownloadManager.shared.removeDownload(ratingKey: track.ratingKey) }
        } else {
            Button("Download for Offline") { model.download(track) }
        }
    }
}

/// Small download/offline indicator for a track row.
struct OfflineBadge: View {
    @ObservedObject private var downloads = DownloadManager.shared
    let ratingKey: String

    var body: some View {
        if downloads.isDownloading(ratingKey) {
            ProgressView().controlSize(.mini)
        } else if downloads.isDownloaded(ratingKey) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// Downloaded marker for an album or a playlist: filled when every track is
/// on the NAS, outlined with a count when only some are, spinner while busy.
struct CollectionBadge: View {
    @ObservedObject private var downloads = DownloadManager.shared
    var collection: PlexMetadata? = nil
    var trackKeys: [String]? = nil

    var body: some View {
        let state = trackKeys.map { downloads.state(of: $0) }
            ?? collection.map { downloads.state(ofCollection: $0) } ?? .none
        switch state {
        case .none: EmptyView()
        case .full:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).font(.caption)
                .help("Downloaded to the NAS")
        case .partial(let d, let t):
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).font(.caption)
                .help("\(d) of \(t) tracks downloaded")
        case .downloading(let d, let t):
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text("\(d)/\(t)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .help("Downloading to the NAS")
        }
    }
}

func durationText(_ ms: Int?) -> String {
    guard let ms else { return "" }
    let s = ms / 1000
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// ♥ for the track that's playing: loving it grows the « Radio ♥ » playlist.
struct HeartButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    var font: Font = .body
    var tint: Color? = nil

    var body: some View {
        let _ = model.likesVersion   // redraw on toggle
        let liked = model.isLikedCurrent()
        Button { model.toggleLikeCurrent() } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? AnyShapeStyle(Color.pink) : (tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)))
        }
        .font(font)
        .buttonStyle(.borderless)
        .disabled(player.current == nil)
        .help(liked ? "Unlove" : "Love — grows the Radio ♥ playlist")
    }
}

/// Visible selection drawn INSIDE the row. `.listRowBackground` is ignored by
/// macOS in sidebar-style lists (every NavigationSplitView column), so the
/// previous 22 % tint never showed: users couldn't tell what was selected.
struct SelectedRow: ViewModifier {
    @ObservedObject private var theme = ThemeManager.shared
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? theme.accent.color.opacity(0.30) : .clear)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5).fill(theme.accent.color)
                        .frame(width: 3).padding(.vertical, 3)
                }
            }
            .fontWeight(isSelected ? .semibold : nil)
    }
}

extension View {
    func selectedRow(_ isSelected: Bool) -> some View { modifier(SelectedRow(isSelected: isSelected)) }
}

/// Remembers a NavigationSplitView column's width across launches.
/// SwiftUI has no autosave for split columns: the width the user drags is
/// measured here, stored per column, and fed back as the column's ideal
/// width on the next launch.
struct PersistedColumnWidth: ViewModifier {
    let key: String
    let min: CGFloat
    let ideal: CGFloat
    let max: CGFloat
    @State private var pending: Task<Void, Never>?

    private var saved: CGFloat {
        let v = UserDefaults.standard.double(forKey: "column.\(key)")
        return v > 0 ? Swift.min(Swift.max(CGFloat(v), min), max) : ideal
    }

    func body(content: Content) -> some View {
        content
            .navigationSplitViewColumnWidth(min: min, ideal: saved, max: max)
            .background(GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width) { _, w in store(w) }
            })
    }

    /// Debounced: a drag fires dozens of changes.
    private func store(_ w: CGFloat) {
        guard w >= min, w <= max else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(Double(w), forKey: "column.\(key)")
        }
    }
}

extension View {
    func persistedColumnWidth(_ key: String, min: CGFloat, ideal: CGFloat, max: CGFloat) -> some View {
        modifier(PersistedColumnWidth(key: key, min: min, ideal: ideal, max: max))
    }
}

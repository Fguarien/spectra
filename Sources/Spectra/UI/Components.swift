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

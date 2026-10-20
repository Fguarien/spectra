import SwiftUI

struct AlbumRow: View {
    let album: PlexMetadata
    var imageURL: URL? = nil      // retained for callers; AlbumArtwork handles the fallback

    var body: some View {
        HStack {
            AlbumArtwork(item: album, side: 40)
            VStack(alignment: .leading) {
                Text(album.title)
                if let year = album.year {
                    Text(String(year)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            CollectionBadge(collection: album)
        }
    }
}

struct TrackListView: View {
    @EnvironmentObject var model: AppModel
    let album: PlexMetadata?
    let tracks: [PlexMetadata]

    var body: some View {
        if let album {
            VStack(spacing: 0) {
                header(album)
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.ratingKey) { pair in
                        TrackRow(index: pair.offset, track: pair.element,
                                 albumTitle: album.title, artist: album.parentTitle ?? "")
                            .contentShape(Rectangle())
                            .onTapGesture { playFrom(index: pair.offset, album: album) }
                            .contextMenu {
                                TrackMenu(track: pair.element, albumTitle: album.title,
                                          artist: album.parentTitle ?? "")
                            }
                    }
                }
            }
            .navigationTitle(album.title)
        } else {
            Text("Select an album").foregroundStyle(.secondary)
        }
    }

    private func header(_ album: PlexMetadata) -> some View {
        HStack(spacing: 14) {
            AlbumArtwork(item: album, side: 88)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title).font(.title3).fontWeight(.semibold)
                Text(album.parentTitle ?? "").foregroundStyle(.secondary)
                HStack {
                    Button {
                        playFrom(index: 0, album: album)
                    } label: { Label("Play", systemImage: "play.fill") }
                    Button { model.downloadAll(tracks, collection: album) } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(tracks.isEmpty)
                    .help("Download the whole album to the NAS")
                    CollectionBadge(trackKeys: tracks.map(\.ratingKey))
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private func playFrom(index: Int, album: PlexMetadata) {
        model.play(tracks, startAt: index, albumTitle: album.title, artist: album.parentTitle ?? "")
    }
}

struct TrackRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    @ObservedObject private var theme = ThemeManager.shared
    let index: Int
    let track: PlexMetadata
    let albumTitle: String
    let artist: String

    /// Clicking a track plays it, so "selected" = the track playing now.
    private var isPlaying: Bool { player.current?.id == track.ratingKey }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if isPlaying {
                    Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundStyle(theme.accent.color)
                } else {
                    Text(track.index.map(String.init) ?? "\(index + 1)").foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, alignment: .trailing)
            Text(track.title).lineLimit(1)
                .foregroundStyle(isPlaying ? AnyShapeStyle(theme.accent.color) : AnyShapeStyle(.primary))
            Spacer()
            OfflineBadge(ratingKey: track.ratingKey)
            StarRatingView(rating: currentRating, compact: true) { model.rate(track, stars: $0) }
            Text(durationText(track.duration)).foregroundStyle(.secondary).font(.callout)
                .frame(width: 44, alignment: .trailing)
        }
        .selectedRow(isPlaying)
    }

    private var currentRating: Int {
        model.rating(track.ratingKey) ?? track.userRating.map { Int($0 / 2) } ?? 0
    }
}

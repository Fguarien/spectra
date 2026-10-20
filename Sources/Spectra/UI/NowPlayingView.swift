import SwiftUI

/// What's playing, large: big cover, track info, rating, transport, and the
/// queue alongside. Double-click the cover for a full-window view.
struct NowPlayingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    @State private var fullCover = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                cover
                    .frame(maxWidth: 480, maxHeight: 480)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(radius: 18, y: 8)
                    .onTapGesture(count: 2) { fullCover = true }
                    .help("Double-click to enlarge")
                VStack(spacing: 4) {
                    Text(player.current?.title ?? "Not playing")
                        .font(.title2).fontWeight(.semibold).lineLimit(2).multilineTextAlignment(.center)
                    Text(player.current?.artist ?? "").font(.title3).foregroundStyle(.secondary)
                    if let album = player.current?.album, !album.isEmpty {
                        Text(album).foregroundStyle(.secondary)
                    }
                }
                if player.current != nil {
                    StarRatingView(rating: player.current?.userRating ?? 0, compact: false) { model.rateCurrent(stars: $0) }
                    TransportButtons(size: .title)
                }
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity)

            Divider()
            QueueView().frame(width: 320)
        }
        .sheet(isPresented: $fullCover) {
            cover
                .frame(minWidth: 700, minHeight: 700)
                .onTapGesture { fullCover = false }
        }
    }

    private var cover: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ArtworkView(url: player.current?.largeArtworkURL ?? player.current?.artworkURL, side: side)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Previous / play-pause / next, shared by Now Playing and the mini player.
struct TransportButtons: View {
    @ObservedObject private var player = AudioPlayer.shared
    var size: Font = .title2

    var body: some View {
        HStack(spacing: 22) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { player.next() } label: { Image(systemName: "forward.fill") }
        }
        .font(size)
        .buttonStyle(.borderless)
    }
}

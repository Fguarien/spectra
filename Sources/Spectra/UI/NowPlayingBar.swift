import SwiftUI

/// Persistent transport bar across the bottom of the window.
struct NowPlayingBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    @State private var showQueue = false

    var body: some View {
        HStack(spacing: 14) {
            ArtworkView(url: player.current?.artworkURL, side: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "Not playing").fontWeight(.medium).lineLimit(1)
                Text(player.current.map { "\($0.artist) — \($0.album)" } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if player.current != nil {
                    StarRatingView(rating: player.current?.userRating ?? 0, compact: true) { model.rateCurrent(stars: $0) }
                }
            }
            .frame(width: 200, alignment: .leading)

            Spacer()

            HStack(spacing: 16) {
                Button { player.shuffle.toggle() } label: { Image(systemName: "shuffle") }
                    .foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                Button { player.cycleRepeat() } label: { Image(systemName: repeatIcon) }
                    .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .buttonStyle(.borderless)

            Spacer()

            HStack(spacing: 8) {
                Text(timeText(player.currentTime)).font(.caption).monospacedDigit()
                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 1)
                )
                .frame(width: 200)
                Text(timeText(player.duration)).font(.caption).monospacedDigit()
            }

            Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showQueue, arrowEdge: .top) { QueueView().frame(width: 360, height: 420) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(height: 76)
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

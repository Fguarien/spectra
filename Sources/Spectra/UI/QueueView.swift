import SwiftUI

/// The play queue: tap to jump, drag to reorder, trash to remove.
struct QueueView: View {
    @ObservedObject private var player = AudioPlayer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Up Next").font(.headline).padding(12)
            Divider()
            if player.queue.isEmpty {
                Spacer(); Text("Queue is empty").foregroundStyle(.secondary).frame(maxWidth: .infinity); Spacer()
            } else {
                List {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { pair in
                        HStack {
                            Image(systemName: pair.offset == player.currentIndex ? "speaker.wave.2.fill" : "music.note")
                                .foregroundStyle(pair.offset == player.currentIndex ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pair.element.title).lineLimit(1)
                                Text(pair.element.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { player.remove(atQueueIndex: pair.offset) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.jump(toQueueIndex: pair.offset) }
                    }
                    .onMove { from, to in player.move(fromOffsets: from, toOffset: to) }
                }
                .listStyle(.inset)
            }
        }
    }
}

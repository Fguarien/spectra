import SwiftUI

/// Music's right panel: « Playing Next » (tap to jump, drag to reorder,
/// × to remove) and « History » (songs played, most recent first).
struct QueueView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = AudioPlayer.shared
    @AppStorage("queue.tab") private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                Text("Playing Next").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(10)
            Divider()
            if tab == 1 {
                HistoryList()
            } else if player.queue.isEmpty {
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

struct HistoryList: View {
    @EnvironmentObject var model: AppModel
    @State private var items: [(Date, PlexMetadata)] = []

    var body: some View {
        Group {
            if items.isEmpty {
                VStack { Spacer(); Text("Nothing played yet").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        HStack(spacing: 8) {
                            ArtworkView(url: model.provider(for: it.1)?.artworkURL(it.1.thumb ?? it.1.parentThumb, size: 80), side: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.1.title).lineLimit(1)
                                Text(it.1.grandparentTitle ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(it.0.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.play([it.1], startAt: 0) }
                        .contextMenu {
                            Button("Play") { model.play([it.1], startAt: 0) }
                            Button("Play Next") { model.enqueue(it.1, albumTitle: "", artist: "", playNext: true) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !items.isEmpty {
                Button("Clear History") { AppDatabase.shared.clearHistory(); items = [] }
                    .buttonStyle(.borderless).font(.caption).padding(8)
            }
        }
        .task(id: model.historyVersion) { items = AppDatabase.shared.history() }
    }
}

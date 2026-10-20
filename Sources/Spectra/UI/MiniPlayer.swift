import SwiftUI
import AppKit

/// Floating, always-on-top square: the current cover, with title and
/// previous / play-pause / next revealed on hover. An AppKit panel rather than
/// a SwiftUI `Window` so it works on macOS 14 (`.windowLevel` is macOS 15).
@MainActor
final class MiniPlayer {
    static let shared = MiniPlayer()
    private var panel: NSPanel?
    private let side: CGFloat = 220

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        show()
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                            backing: .buffered, defer: false)
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.contentView = NSHostingView(rootView: MiniPlayerView(side: side) { [weak self] in
                self?.panel?.orderOut(nil)
            })
            // Remembers where the user left it across launches.
            if !p.setFrameUsingName("SpectraMiniPlayer") {
                if let screen = NSScreen.main?.visibleFrame {
                    p.setFrameOrigin(NSPoint(x: screen.maxX - side - 24, y: screen.minY + 24))
                }
            }
            p.setFrameAutosaveName("SpectraMiniPlayer")
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

struct MiniPlayerView: View {
    @ObservedObject private var player = AudioPlayer.shared
    let side: CGFloat
    let close: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack {
            ArtworkView(url: player.current?.largeArtworkURL ?? player.current?.artworkURL, side: side)
            if hover || player.current == nil {
                LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0.1), .black.opacity(0.6)],
                               startPoint: .bottom, endPoint: .top)
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).font(.title3)
                    }
                    Spacer()
                    Text(player.current?.title ?? "Not playing")
                        .font(.headline).lineLimit(1)
                    Text(player.current?.artist ?? "").font(.caption).lineLimit(1).opacity(0.85)
                    TransportButtons(size: .title2).padding(.top, 8)
                }
                .foregroundStyle(.white)
                .padding(12)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.15), value: hover)
    }
}

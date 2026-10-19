import SwiftUI
import AppKit

@main
struct SpectraApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { model.bootstrap() }
        }
        .windowStyle(.titleBar)
        .commands { SpectraCommands() }

        Window("Spectra Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)
    }
}

/// Menu bar: a real About panel, a Playback menu with keyboard shortcuts, and
/// the Help menu opening the in-app help window.
struct SpectraCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Spectra") { Self.showAbout() }
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { AudioPlayer.shared.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Next") { AudioPlayer.shared.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { AudioPlayer.shared.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Spectra Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    @MainActor private static func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Native macOS client for Plex music. Original code — reimplemented against Plex’s public HTTP API.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }
}

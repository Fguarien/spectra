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
        .windowToolbarStyle(.unified)
        .commands { SpectraCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
                .formStyle(.grouped)
                .frame(width: 600, height: 680)
                .tint(ThemeManager.shared.accent.color)
        }

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
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Spectra") { Self.showAbout() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Playlist…") { model.newLocalPlaylist() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Add Plex Account…") { model.startLink() }
            Button("Add Local Folder…") { model.promptAddLocalFolder() }
            Button("Add YouTube Music") { model.promptAddYouTubeMusic() }
        }
        CommandGroup(after: .sidebar) {
            Button("Recently Added") { model.openAlbum = nil; model.pane = .recentlyAdded }.keyboardShortcut("1", modifiers: .command)
            Button("Artists") { model.openAlbum = nil; model.pane = .artists }.keyboardShortcut("2", modifiers: .command)
            Button("Albums") { model.openAlbum = nil; model.pane = .albums }.keyboardShortcut("3", modifiers: .command)
            Button("Songs") { model.openAlbum = nil; model.pane = .songs }.keyboardShortcut("4", modifiers: .command)
            Button("Genres") { model.openAlbum = nil; model.pane = .genres }.keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Refresh Library") { model.refreshCatalog(force: true) }.keyboardShortcut("r", modifiers: .command)
            Divider()
        }
        CommandMenu("Playback") {
            Button("Play / Pause") { AudioPlayer.shared.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Next") { AudioPlayer.shared.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { AudioPlayer.shared.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Shuffle") { AudioPlayer.shared.shuffle.toggle() }
            Button("Repeat") { AudioPlayer.shared.cycleRepeat() }
            Divider()
            Button("Increase Volume") { AudioPlayer.shared.volume = min(1, AudioPlayer.shared.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Decrease Volume") { AudioPlayer.shared.volume = max(0, AudioPlayer.shared.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button("Mini Player") { MiniPlayer.shared.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Full Screen Player") { NotificationCenter.default.post(name: .spectraFullScreenPlayer, object: nil) }
                .keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Button("Love Current Song") { model.toggleLikeCurrent() }
                .keyboardShortcut("l", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Spectra Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    @MainActor private static func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Native macOS music player for Plex, local files and YouTube Music. Original code, MIT licence.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }
}

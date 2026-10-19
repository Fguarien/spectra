import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

    var body: some View {
        content
            .tint(theme.accent.color)
            .preferredColorScheme(theme.appearance.colorScheme)
            .dynamicTypeSize(theme.textSize.dynamicTypeSize)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .signedOut, .linking:
            LoginView()
        case .loading:
            ProgressView("Connecting to Plex…").controlSize(.large)
        case .ready:
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Sidebar()
                    Divider()
                    paneView.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                NowPlayingBar()
            }
        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button("Sign out") { model.signOut() }
            }
        }
    }

    @ViewBuilder private var paneView: some View {
        switch model.pane {
        case .library:   LibraryView()
        case .playlists: PlaylistsView()
        case .search:    SearchView()
        case .downloads: DownloadsView()
        case .settings:  SettingsView()
        }
    }
}

/// Left navigation rail — the app's top-level sections, Prism-style.
struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    private let items: [(AppModel.Pane, String, String)] = [
        (.library, "Library", "music.note.house"),
        (.playlists, "Playlists", "music.note.list"),
        (.search, "Search", "magnifyingglass"),
        (.downloads, "Downloads", "arrow.down.circle"),
        (.settings, "Settings", "gearshape"),
    ]

    var body: some View {
        List(selection: Binding(get: { model.pane }, set: { model.pane = $0 })) {
            Section(model.serverName) {
                ForEach(items, id: \.0) { pane, label, icon in
                    Label(label, systemImage: icon).tag(pane)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
    }
}

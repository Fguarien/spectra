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

/// Left navigation rail — the app's top-level sections, Prism-style, with an
/// account switcher at the top (A2: several accounts, across providers).
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
        VStack(spacing: 0) {
            accountMenu.padding(8)
            Divider()
            List(selection: Binding(get: { model.pane }, set: { model.pane = $0 })) {
                ForEach(items, id: \.0) { pane, label, icon in
                    Label(label, systemImage: icon).tag(pane)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 200)
    }

    private var accountMenu: some View {
        Menu {
            ForEach(model.accounts) { acc in
                Button { model.switchAccount(acc.id) } label: {
                    Label("\(acc.name)\(acc.id == model.activeAccountID ? " ✓" : "")",
                          systemImage: acc.kind.systemImage)
                }
            }
            if !model.accounts.isEmpty { Divider() }
            Button { model.startLink() } label: { Label("Add Plex Account…", systemImage: "plus") }
            Button { model.promptAddLocalFolder() } label: { Label("Add Local Folder…", systemImage: "folder.badge.plus") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                Text(model.serverName.isEmpty ? "Account" : model.serverName).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
    }
}

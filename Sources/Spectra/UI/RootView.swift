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
            ProgressView(model.statusLabel).controlSize(.large)
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) { GlobalSearchField() }
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
        case .nowPlaying: NowPlayingView()
        case .library:   LibraryView()
        case .allSources: AllSourcesView()
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
        (.nowPlaying, "Now Playing", "play.circle"),
        (.library, "Library", "music.note.house"),
        (.allSources, "All Sources", "square.stack.3d.up"),
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
            Button { model.promptAddYouTubeMusic() } label: { Label("Add YouTube Music", systemImage: "play.rectangle") }
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

/// Persistent search field in the window toolbar: searches every connected
/// account as you type (debounced) and jumps to the Search pane.
struct GlobalSearchField: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search all sources", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .onSubmit { model.runSearch(model.searchQuery) }
                .onChange(of: model.searchQuery) { _, _ in model.scheduleSearch() }
            if !model.searchQuery.isEmpty {
                Button { model.searchQuery = ""; model.searchHits = [] } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 260)
    }
}

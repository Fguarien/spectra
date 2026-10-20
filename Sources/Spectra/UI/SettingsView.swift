import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared
    @AppStorage("notifyOnTrackChange") private var notifyOnTrackChange = true
    @ObservedObject private var lastfm = LastFM.shared
    @ObservedObject private var radio = RadioBuilder.shared
    @ObservedObject private var catalog = CatalogStore.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme.appearance) {
                    ForEach(ThemeManager.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Accent", selection: $theme.accent) {
                    ForEach(ThemeManager.Accent.allCases) { a in
                        HStack { Circle().fill(a.color).frame(width: 12, height: 12); Text(a.label) }.tag(a)
                    }
                }
                Picker("Text Size", selection: $theme.textSize) {
                    ForEach(ThemeManager.TextSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Notifications") {
                Toggle("Notify on track change", isOn: $notifyOnTrackChange)
                Text("Shows a notification with the track, artist and album when the song changes while Spectra is in the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage (NAS)") {
                LabeledContent("Folder", value: Storage.root.path)
                LabeledContent("Status", value: Storage.isAvailable ? "Mounted" : "Not mounted — downloads wait")
                Text("Downloads go to Music/<Artist>/<Album>/ with a cover.jpg; cover art cache and database backups live here too. The live database stays on this Mac (SQLite over SMB can corrupt); a consistent copy is saved hourly and on quit, 48 kept.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Back Up Now") { model.backupNow() }
                    Button("Restore from Backup…") { model.promptRestore() }
                }
                .buttonStyle(.bordered).controlSize(.small)
                if let msg = model.backupMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Radio ♥") {
                Picker("Tracks per radio", selection: $radio.length) {
                    ForEach(RadioBuilder.lengths, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Loving a track (♥) creates the playlist “Radio ♥ — <title>”: the loved track, then similar ones from Last.fm, curated by a local model and found in your sources (Local, Plex, YouTube Music).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Last.fm") {
                if let user = lastfm.username {
                    HStack {
                        Label("Scrobbling as \(user)", systemImage: "dot.radiowaves.left.and.right")
                        Spacer()
                        Button("Disconnect") { lastfm.disconnect() }.buttonStyle(.borderless)
                    }
                } else {
                    Button("Connect Last.fm…") { lastfm.connect() }
                        .disabled(!lastfm.hasAPIKey)
                    if !lastfm.hasAPIKey {
                        Text("No Last.fm API key installed yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Scrobble plays", isOn: $lastfm.enabled)
                Toggle("Also scrobble Plex plays", isOn: $lastfm.scrobblePlex)
                Text("Leave off if your Plex account already scrobbles to Last.fm, to avoid duplicates. A track is scrobbled after half its length or 4 minutes of listening.")
                    .font(.caption).foregroundStyle(.secondary)
                if lastfm.pendingCount > 0 {
                    Text("\(lastfm.pendingCount) scrobble(s) waiting to be sent.").font(.caption)
                }
                if let s = lastfm.status { Text(s).font(.caption).foregroundStyle(.orange) }
            }

            Section("Prism Import") {
                if let msg = model.importMessage {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                }
                Button("Import from Prism Items.db…") { pickPrismDB() }
                Text("Choose the Items.db pulled from Prism’s .imazingapp container. Ratings, play history, tags, similar artists and playlists are migrated.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Library") {
                ForEach(model.accounts) { acc in
                    LabeledContent {
                        if catalog.syncing.contains(acc.id) { ProgressView().controlSize(.small) }
                        else if let e = catalog.errors[acc.id] { Text(e).foregroundStyle(.red).lineLimit(2) }
                        else {
                            Text("\(AppDatabase.shared.catalogCount(acc.id)) songs · "
                                 + (AppDatabase.shared.catalogSyncedAt(acc.id)?.formatted(date: .abbreviated, time: .shortened) ?? "never"))
                        }
                    } label: { Label(acc.name, systemImage: acc.kind.systemImage) }
                }
                Button("Refresh Library Now") { model.refreshCatalog(force: true) }
                Text("Every source is listed into the local database (backed up to the NAS with it) and re-listed when its copy is an hour old.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Accounts") {
                ForEach(model.accounts) { acc in
                    HStack(spacing: 10) {
                        Image(systemName: acc.kind.systemImage).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(acc.name)
                            Text(acc.id == model.activeAccountID ? "\(acc.kind.label) · active" : acc.kind.label)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if acc.id == model.activeAccountID {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        } else {
                            Button("Switch") { model.switchAccount(acc.id) }.buttonStyle(.borderless)
                        }
                        Button(role: .destructive) { model.removeAccount(acc.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Plex…") { model.startLink() }
                    Button("Add Local Folder…") { model.promptAddLocalFolder() }
                    Button("Add YouTube Music") { model.promptAddYouTubeMusic() }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 560)
        .padding(20)
    }

    private func pickPrismDB() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Prism Items.db exported from the .imazingapp"
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            model.runImport(prismDBPath: url.path)
        }
    }
}

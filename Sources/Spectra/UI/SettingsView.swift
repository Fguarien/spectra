import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var theme = ThemeManager.shared

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

            Section("Prism Import") {
                if let msg = model.importMessage {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                }
                Button("Import from Prism Items.db…") { pickPrismDB() }
                Text("Choose the Items.db pulled from Prism’s .imazingapp container. Ratings, play history, tags, similar artists and playlists are migrated.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Account") {
                LabeledContent("Server", value: model.serverName)
                LabeledContent("Local library", value: "\(AppDatabase.shared.trackCount()) tracks, \(AppDatabase.shared.tags().count) tags")
                Button("Sign out", role: .destructive) { model.signOut() }
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

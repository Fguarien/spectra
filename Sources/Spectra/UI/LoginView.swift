import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .resizable().frame(width: 72, height: 72)
                .foregroundStyle(.tint)
            Text("Spectra").font(.largeTitle.bold())
            Text("A native music player for Plex and your local files.")
                .foregroundStyle(.secondary)

            if case .linking = model.phase {
                ProgressView()
                if let code = model.linkCode {
                    Text("Approve the sign-in in your browser.").font(.callout)
                    Text("Link code: \(code)").font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                VStack(spacing: 12) {
                    Button("Connect to Plex") { model.startLink() }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    Button("Add a Local Folder") { model.promptAddLocalFolder() }
                        .controlSize(.large)
                    Button("Add YouTube Music") { model.promptAddYouTubeMusic() }
                        .controlSize(.large)
                }
            }
        }
        .padding(60)
    }
}

import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .resizable().frame(width: 72, height: 72)
                .foregroundStyle(.tint)
            Text("Spectra").font(.largeTitle.bold())
            Text("A native music player for your Plex library.")
                .foregroundStyle(.secondary)

            if case .linking = model.phase {
                ProgressView()
                if let code = model.linkCode {
                    Text("Approve the sign-in in your browser.").font(.callout)
                    Text("Link code: \(code)").font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else {
                Button("Connect to Plex") { model.startLink() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(60)
    }
}

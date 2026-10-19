import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .signedOut, .linking:
            LoginView()
        case .loading:
            ProgressView("Connecting to Plex…").controlSize(.large)
        case .ready:
            VStack(spacing: 0) {
                LibraryView()
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
}

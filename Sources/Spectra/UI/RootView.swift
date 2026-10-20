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
            MusicWindow()
        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center).padding(.horizontal, 40)
                Button("Sign out") { model.signOut() }
            }
        }
    }
}

/// Progress / result of a Radio ♥ build, floating above the transport bar.
struct RadioToast: View {
    @ObservedObject private var radio = RadioBuilder.shared

    var body: some View {
        if let s = radio.status {
            Label(s, systemImage: "heart.fill")
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
        }
    }
}

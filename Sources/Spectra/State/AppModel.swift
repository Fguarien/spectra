import Foundation
import SwiftUI
import AppKit

/// Top-level app state: authentication, the Plex client, and the current
/// music section. Drives which root screen is shown.
@MainActor
final class AppModel: ObservableObject {
    enum Phase { case signedOut, linking, loading, ready, error(String) }

    @Published var phase: Phase = .signedOut
    @Published var linkCode: String?          // shown while the user approves in-browser
    @Published var serverName = ""
    @Published var sections: [PlexSection] = []
    @Published var artists: [PlexMetadata] = []
    @Published var importMessage: String?

    private(set) var client: PlexClient?
    private let auth = PlexAuth()
    private let tokenAccount = "plex.account.token"

    func bootstrap() {
        if let token = Keychain.get(account: tokenAccount) {
            Task { await connect(token: token) }
        } else {
            phase = .signedOut
        }
    }

    // MARK: sign-in

    func startLink() {
        phase = .linking
        Task {
            do {
                let pin = try await auth.requestPIN()
                linkCode = pin.code
                NSWorkspace.shared.open(auth.authURL(code: pin.code))
                let token = try await auth.pollForToken(pin: pin)
                Keychain.set(token, account: tokenAccount)
                await connect(token: token)
            } catch {
                phase = .error("Linking failed: \(error.localizedDescription)")
            }
        }
    }

    func signOut() {
        Keychain.delete(account: tokenAccount)
        client = nil
        sections = []; artists = []; serverName = ""
        phase = .signedOut
    }

    // MARK: connect + load

    private func connect(token: String) async {
        phase = .loading
        let c = PlexClient(accountToken: token)
        do {
            try await c.discoverServer()
            client = c
            serverName = c.serverName
            AudioPlayer.shared.onTimeline = { key, state, t, d in
                Task { await c.reportTimeline(ratingKey: key, state: state, timeMs: t, durationMs: d) }
            }
            let secs = try await c.musicSections()
            sections = secs
            if let first = secs.first {
                artists = try await c.artists(sectionKey: first.key)
            }
            phase = .ready
        } catch {
            phase = .error("Could not reach your Plex server: \(error.localizedDescription)")
        }
    }

    // MARK: browse helpers

    func albums(of artist: PlexMetadata) async -> [PlexMetadata] {
        (try? await client?.children(ratingKey: artist.ratingKey)) ?? []
    }

    func tracks(of album: PlexMetadata) async -> [PlexMetadata] {
        (try? await client?.children(ratingKey: album.ratingKey)) ?? []
    }

    func playable(_ m: PlexMetadata, albumTitle: String, artist: String) -> PlayableTrack? {
        guard let part = m.firstPartKey, let url = client?.streamURL(partKey: part) else { return nil }
        return PlayableTrack(
            id: m.ratingKey,
            title: m.title,
            artist: artist,
            album: albumTitle,
            url: url,
            durationMs: m.duration ?? 0,
            artworkURL: client?.imageURL(thumb: m.thumb)
        )
    }

    func imageURL(_ thumb: String?, size: Int = 300) -> URL? {
        client?.imageURL(thumb: thumb, size: size)
    }

    // MARK: Prism import

    func runImport(prismDBPath: String) {
        importMessage = "Importing…"
        Task.detached {
            do {
                let s = try Importer.importProm(from: prismDBPath)
                await MainActor.run { self.importMessage = "Imported \(s.tracks) tracks, \(s.plays) plays from Prism." }
            } catch {
                await MainActor.run { self.importMessage = "Import failed: \(error.localizedDescription)" }
            }
        }
    }
}

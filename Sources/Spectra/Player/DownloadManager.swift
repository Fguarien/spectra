import Foundation
import AppKit
import Combine

/// Downloads tracks for offline playback onto the NAS (`Storage`, default
/// `/Volumes/music/Spectra/Music/<Artist>/<Album>/`), with a `cover.jpg` per
/// album folder, and records the path in the database so AppModel prefers it
/// over streaming.
///
/// - At most two downloads run at once (a playlist enqueues dozens).
/// - NAS not mounted → the request is parked (persisted) and replayed when the
///   share comes back; nothing is ever written to the Mac's disk by mistake.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// ratingKey → 0…1 progress while in flight (0 = queued or running).
    @Published private(set) var inFlight: [String: Double] = [:]
    /// ratingKeys that have a copy on the NAS.
    @Published private(set) var downloaded: Set<String> = []
    /// Last failure, shown in the Downloads pane.
    @Published private(set) var lastError: String?
    /// Requests waiting for the NAS.
    @Published private(set) var parkedCount = 0
    /// Albums / playlists asked for as a whole: collection key → its tracks'
    /// ratingKeys, so a row can show "downloaded" without loading its tracks.
    @Published private(set) var collections: [String: [String]] =
        (UserDefaults.standard.dictionary(forKey: "downloads.collections") as? [String: [String]]) ?? [:]

    static func collectionKey(_ m: PlexMetadata) -> String { "\(m.sourceAccountID ?? "")|\(m.ratingKey)" }

    func remember(collection m: PlexMetadata, tracks: [PlexMetadata]) {
        guard !tracks.isEmpty else { return }
        collections[Self.collectionKey(m)] = tracks.map(\.ratingKey)
        UserDefaults.standard.set(collections, forKey: "downloads.collections")
    }

    enum State: Equatable { case none, downloading(Int, Int), partial(Int, Int), full }

    /// State of a set of tracks: all on the NAS, some, in progress, or none.
    func state(of keys: [String]) -> State {
        guard !keys.isEmpty else { return .none }
        let done = keys.filter(downloaded.contains).count
        if keys.contains(where: { inFlight[$0] != nil }) { return .downloading(done, keys.count) }
        if done == keys.count { return .full }
        return done == 0 ? .none : .partial(done, keys.count)
    }

    func state(ofCollection m: PlexMetadata) -> State {
        collections[Self.collectionKey(m)].map(state(of:)) ?? .none
    }

    /// Called to replay a parked request (set by AppModel, which owns providers).
    var resume: ((PlexMetadata) -> Bool)?

    struct Meta {
        let ratingKey: String
        let title: String
        let artist: String?
        let album: String?
        let index: Int?
        let durationMs: Int
        let ext: String
        let coverURL: URL?
    }

    private struct Job {
        let meta: Meta
        let write: (URL) async throws -> Void
    }

    private let session = URLSession(configuration: .default)
    private var waiting: [Job] = []
    private var running = 0
    private let slots = 2
    private let parkedKey = "downloads.parked"
    private var timer: Timer?

    private init() {
        downloaded = AppDatabase.shared.downloadedKeys()
        parkedCount = parked.count
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.replayParked() } }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.replayParked() }
        }
    }

    func isDownloaded(_ ratingKey: String) -> Bool { downloaded.contains(ratingKey) }
    func isDownloading(_ ratingKey: String) -> Bool { inFlight[ratingKey] != nil }

    // MARK: parking while the NAS is away

    private var parked: [PlexMetadata] {
        get { UserDefaults.standard.data(forKey: parkedKey).flatMap { try? JSONDecoder().decode([PlexMetadata].self, from: $0) } ?? [] }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: parkedKey)
            parkedCount = newValue.count
        }
    }

    func park(_ m: PlexMetadata) {
        guard !downloaded.contains(m.ratingKey), !parked.contains(m) else { return }
        parked = parked + [m]
        lastError = "NAS share not mounted — \(parkedCount) download(s) waiting for \(Storage.root.path)."
    }

    /// Replay parked requests once the share is back. A request whose account
    /// isn't connected yet stays parked for the next pass.
    func replayParked() {
        guard !parked.isEmpty, Storage.isAvailable, let resume else { return }
        parked = parked.filter { !resume($0) }
        if parked.isEmpty, lastError?.hasPrefix("NAS share") == true { lastError = nil }
    }

    // MARK: enqueue

    /// Fetch `url` (a direct stream / file URL) into the NAS layout.
    func download(_ meta: Meta, from url: URL) {
        enqueue(meta) { [session] dest in
            let (tmp, resp) = try await session.download(from: url)
            if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)   // cross-volume: copies
        }
    }

    /// Let the provider write the file itself (yt-dlp for YouTube Music).
    func download(_ meta: Meta, writer: @escaping (URL) async throws -> Void) {
        enqueue(meta, write: writer)
    }

    private func enqueue(_ meta: Meta, write: @escaping (URL) async throws -> Void) {
        guard inFlight[meta.ratingKey] == nil, !downloaded.contains(meta.ratingKey) else { return }
        inFlight[meta.ratingKey] = 0
        waiting.append(Job(meta: meta, write: write))
        pump()
    }

    private func pump() {
        while running < slots, !waiting.isEmpty {
            let job = waiting.removeFirst()
            running += 1
            Task {
                await run(job)
                running -= 1
                pump()
            }
        }
    }

    private func run(_ job: Job) async {
        let m = job.meta
        guard let dest = Storage.trackFile(artist: m.artist, album: m.album, index: m.index,
                                           title: m.title, ext: m.ext) else {
            inFlight[m.ratingKey] = nil
            lastError = "NAS share not mounted — “\(m.title)” not downloaded."
            return
        }
        do {
            try await job.write(dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            guard size > 0 else { throw URLError(.zeroByteResource) }
            AppDatabase.shared.setLocalPath(dest.path, ratingKey: m.ratingKey, title: m.title,
                                            artist: m.artist, album: m.album,
                                            durationMs: m.durationMs, codec: m.ext)
            downloaded.insert(m.ratingKey)
            await saveCover(m.coverURL, folder: dest.deletingLastPathComponent())
        } catch {
            try? FileManager.default.removeItem(at: dest)
            lastError = "Download failed for “\(m.title)”: \(error.localizedDescription)"
        }
        inFlight[m.ratingKey] = nil
    }

    /// One `cover.jpg` per album folder, the convention Plex, Music.app and
    /// most players read.
    private func saveCover(_ url: URL?, folder: URL) async {
        let cover = folder.appendingPathComponent("cover.jpg")
        guard let url, !FileManager.default.fileExists(atPath: cover.path) else { return }
        if url.isFileURL {
            try? FileManager.default.copyItem(at: url, to: cover)
        } else if let (data, resp) = try? await session.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
            try? data.write(to: cover)
        }
    }

    // MARK: removal / lookup

    func removeDownload(ratingKey: String) {
        if let p = AppDatabase.shared.localPath(forRatingKey: ratingKey) {
            try? FileManager.default.removeItem(atPath: p)
        }
        AppDatabase.shared.setLocalPath(nil, ratingKey: ratingKey, title: nil, artist: nil,
                                        album: nil, durationMs: 0, codec: nil)
        downloaded.remove(ratingKey)
    }

    /// File URL for a downloaded track, if reachable right now (NAS mounted).
    func localURL(_ ratingKey: String) -> URL? {
        AppDatabase.shared.localPath(forRatingKey: ratingKey).map { URL(fileURLWithPath: $0) }
    }

    // MARK: one-off migration from the pre-1.13 local folder

    /// Move downloads made before v1.13 (Application Support/Spectra/Downloads)
    /// onto the NAS and repoint their database rows. Idempotent.
    func migrateLegacyDownloads() {
        guard Storage.isAvailable else { return }
        let legacy = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectra/Downloads", isDirectory: true).path
        for r in AppDatabase.shared.downloadedTracks() {
            guard let path = r.localPath, path.hasPrefix(legacy), let key = r.ratingKey,
                  let dest = Storage.trackFile(artist: r.artistName, album: r.albumTitle,
                                               index: r.trackNumber > 0 ? r.trackNumber : nil,
                                               title: r.trackTitle ?? key,
                                               ext: (path as NSString).pathExtension) else { continue }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(atPath: path, toPath: dest.path)
                AppDatabase.shared.setLocalPath(dest.path, ratingKey: key, title: r.trackTitle,
                                                artist: r.artistName, album: r.albumTitle,
                                                durationMs: r.durationMs, codec: r.codec)
            } catch {
                lastError = "Could not move “\(r.trackTitle ?? key)” to the NAS: \(error.localizedDescription)"
            }
        }
    }
}

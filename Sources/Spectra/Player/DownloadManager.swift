import Foundation
import Combine

/// Downloads tracks for offline playback into Application Support/Spectra/Downloads,
/// and records the local path in the database so AppModel can prefer it over
/// streaming. Downloads the original file (direct stream URL), not a transcode.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    /// ratingKey → 0…1 progress while in flight.
    @Published private(set) var inFlight: [String: Double] = [:]
    /// ratingKeys that have a local copy on disk.
    @Published private(set) var downloaded: Set<String> = []
    /// Last failure, shown in the Downloads pane (was silently swallowed).
    @Published private(set) var lastError: String?

    private let session = URLSession(configuration: .default)

    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Spectra/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() { downloaded = AppDatabase.shared.downloadedKeys() }

    func isDownloaded(_ ratingKey: String) -> Bool { downloaded.contains(ratingKey) }
    func isDownloading(_ ratingKey: String) -> Bool { inFlight[ratingKey] != nil }

    /// Download `track` from `url` (a direct stream URL). Metadata is stored so
    /// the row exists even if the track was never imported from Prism.
    /// Download through a provider-supplied writer (e.g. yt-dlp) instead of a GET.
    func download(ratingKey: String, title: String?, artist: String?, durationMs: Int, codec: String,
                  writer: @escaping (URL) async throws -> Void) {
        guard inFlight[ratingKey] == nil, !downloaded.contains(ratingKey) else { return }
        inFlight[ratingKey] = 0
        let dest = destination(ratingKey, ext: codec)
        Task {
            do {
                try await writer(dest)
                let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
                guard size > 0 else { throw URLError(.zeroByteResource) }
                AppDatabase.shared.setLocalPath(dest.path, ratingKey: ratingKey, title: title,
                                                artist: artist, durationMs: durationMs, codec: codec)
                inFlight[ratingKey] = nil
                downloaded.insert(ratingKey)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                inFlight[ratingKey] = nil
                lastError = "Download failed for “\(title ?? ratingKey)”: \(error.localizedDescription)"
            }
        }
    }

    /// ratingKeys like "yt:<id>" or a local path aren't safe file names.
    private func destination(_ ratingKey: String, ext: String) -> URL {
        let safe = ratingKey.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return dir.appendingPathComponent("\(String(safe)).\(ext)")
    }

    func download(ratingKey: String, from url: URL, title: String?, artist: String?, durationMs: Int, codec: String?) {
        guard inFlight[ratingKey] == nil, !downloaded.contains(ratingKey) else { return }
        inFlight[ratingKey] = 0
        let ext = codec.map { $0.replacingOccurrences(of: "/", with: "") } ?? "audio"
        let dest = destination(ratingKey, ext: ext)
        Task {
            do {
                let (tmp, resp) = try await session.download(from: url)
                if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
                }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                AppDatabase.shared.setLocalPath(dest.path, ratingKey: ratingKey, title: title,
                                                artist: artist, durationMs: durationMs, codec: codec)
                await MainActor.run {
                    self.inFlight[ratingKey] = nil
                    self.downloaded.insert(ratingKey)
                }
            } catch {
                await MainActor.run {
                    self.inFlight[ratingKey] = nil
                    self.lastError = "Download failed for “\(title ?? ratingKey)”: \(error.localizedDescription)"
                }
            }
        }
    }

    func removeDownload(ratingKey: String) {
        if let p = AppDatabase.shared.localPath(forRatingKey: ratingKey) {
            try? FileManager.default.removeItem(atPath: p)
        }
        AppDatabase.shared.setLocalPath(nil, ratingKey: ratingKey, title: nil, artist: nil, durationMs: 0, codec: nil)
        downloaded.remove(ratingKey)
    }

    /// Local file URL for a downloaded track, if present on disk.
    func localURL(_ ratingKey: String) -> URL? {
        AppDatabase.shared.localPath(forRatingKey: ratingKey).map { URL(fileURLWithPath: $0) }
    }
}

import Foundation

/// Where Spectra keeps files the user owns: downloaded music, cover art and
/// database backups. Default root `/Volumes/music/Spectra` — the NAS `music`
/// share (SMB), which `~/Music` points at.
///
/// The trap this guards against: when the share is NOT mounted,
/// `/Volumes/music` can still be created as a plain local folder, and every
/// write would silently land on the Mac's disk. A root under `/Volumes/<x>`
/// is therefore only "available" if `/Volumes/<x>` is a real mount point.
enum Storage {
    static let defaultRoot = "/Volumes/music/Spectra"
    private static let key = "storage.root"

    static var root: URL {
        get { URL(fileURLWithPath: UserDefaults.standard.string(forKey: key) ?? defaultRoot, isDirectory: true) }
        set { UserDefaults.standard.set(newValue.path, forKey: key) }
    }

    /// Mounted (for a /Volumes path) and writable.
    static var isAvailable: Bool {
        let comps = root.standardizedFileURL.pathComponents   // ["/", "Volumes", "music", "Spectra"]
        if comps.count >= 3, comps[1] == "Volumes" {
            let mountPoint = "/Volumes/\(comps[2])"
            var fs = statfs()
            guard statfs(mountPoint, &fs) == 0 else { return false }
            let mountedOn = withUnsafePointer(to: &fs.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            guard mountedOn == mountPoint else { return false }   // a local folder, not the share
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return FileManager.default.isWritableFile(atPath: root.path)
    }

    /// `root/<sub>`, created on demand; nil when the NAS isn't there.
    static func dir(_ sub: String) -> URL? {
        guard isAvailable else { return nil }
        let d = root.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// `Music/<Artist>/<Album>/<NN> <Title>.<ext>` — readable by people and by
    /// other players (Plex, Music.app) pointed at the share.
    static func trackFile(artist: String?, album: String?, index: Int?, title: String, ext: String) -> URL? {
        guard let music = dir("Music") else { return nil }
        let a = safe(artist, fallback: "Unknown Artist")
        let b = safe(album, fallback: "Singles")
        let folder = music.appendingPathComponent(a, isDirectory: true).appendingPathComponent(b, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let n = index.map { String(format: "%02d ", $0) } ?? ""
        return folder.appendingPathComponent("\(n)\(safe(title, fallback: "Track")).\(ext)")
    }

    /// File-name safe on SMB/macOS: no path separators, no characters SMB
    /// rejects, no leading dot, bounded length.
    static func safe(_ s: String?, fallback: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var out = (s ?? "").components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > 120 { out = String(out.prefix(120)) }
        return out.isEmpty ? fallback : out
    }
}

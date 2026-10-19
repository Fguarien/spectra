import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// A playable track as the player needs it (decoupled from Plex/DB models).
struct PlayableTrack: Identifiable, Equatable {
    let id: String          // Plex ratingKey
    let title: String
    let artist: String
    let album: String
    let url: URL
    let durationMs: Int
    let artworkURL: URL?
}

/// AVQueuePlayer-backed engine with a visible queue, transport state and
/// system Now-Playing / remote-command integration.
@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published private(set) var queue: [PlayableTrack] = []
    @Published private(set) var currentIndex: Int? = nil
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    var current: PlayableTrack? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: AnyCancellable?

    /// Called with (ratingKey, state, timeMs, durationMs) for Plex scrobbling.
    var onTimeline: ((String, String, Int, Int) -> Void)?

    private init() {
        setupRemoteCommands()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main
        ) { [weak self] t in
            guard let self else { return }
            self.currentTime = t.seconds
            if let item = self.player.currentItem, item.duration.isNumeric {
                self.duration = item.duration.seconds
            }
            self.updateNowPlayingElapsed()
        }
    }

    // MARK: queue control

    func play(tracks: [PlayableTrack], startAt index: Int = 0) {
        queue = tracks
        start(index: index)
    }

    func append(_ track: PlayableTrack) {
        queue.append(track)
        if currentIndex == nil { start(index: 0) }
    }

    private func start(index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        let track = queue[index]
        let item = AVPlayerItem(url: track.url)
        endObserver = NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .sink { [weak self] _ in self?.next() }
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        emitTimeline(state: "playing")
        updateNowPlayingInfo()
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        player.play(); isPlaying = true
        emitTimeline(state: "playing"); updateNowPlayingElapsed()
    }

    func pause() {
        player.pause(); isPlaying = false
        emitTimeline(state: "paused"); updateNowPlayingElapsed()
    }

    func next() {
        guard let i = currentIndex, i + 1 < queue.count else { emitTimeline(state: "stopped"); return }
        start(index: i + 1)
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard let i = currentIndex, i > 0 else { seek(to: 0); return }
        start(index: i - 1)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlayingElapsed()
    }

    // MARK: timeline / scrobble

    private func emitTimeline(state: String) {
        guard let t = current else { return }
        onTimeline?(t.id, state, Int(currentTime * 1000), t.durationMs)
    }

    // MARK: system Now Playing

    private func updateNowPlayingInfo() {
        guard let t = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: Double(t.durationMs) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        info.removeAll()
    }

    private func updateNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }
}

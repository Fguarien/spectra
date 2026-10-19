import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// A playable track as the player needs it (decoupled from Plex/DB models).
/// `url` is already resolved by AppModel to the best source: a local download,
/// a direct stream, or a Plex transcode URL for unsupported codecs.
struct PlayableTrack: Identifiable, Equatable {
    let id: String          // Plex ratingKey
    let title: String
    let artist: String
    let album: String
    let url: URL
    let durationMs: Int
    let artworkURL: URL?
    var userRating: Int? = nil   // 0…5, mirrored for the transport bar

    static func == (l: PlayableTrack, r: PlayableTrack) -> Bool { l.id == r.id && l.url == r.url }
}

enum RepeatMode { case off, all, one }

/// AVQueuePlayer-backed engine with a visible queue, gapless playback,
/// shuffle / repeat, queue editing and system Now-Playing / remote-command
/// integration.
@MainActor
final class AudioPlayer: ObservableObject {
    static let shared = AudioPlayer()

    @Published private(set) var queue: [PlayableTrack] = []   // user-visible order
    @Published private(set) var currentIndex: Int? = nil       // index into `queue`
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var shuffle = false { didSet { if oldValue != shuffle { reshuffle() } } }
    @Published var repeatMode: RepeatMode = .off

    var current: PlayableTrack? {
        guard let i = currentIndex, queue.indices.contains(i) else { return nil }
        return queue[i]
    }

    private let player = AVQueuePlayer()
    private var order: [Int] = []          // playback order: positions into `queue`
    private var orderPos: Int = 0          // pointer within `order`
    private var itemTracks: [ObjectIdentifier: Int] = [:]  // AVPlayerItem → queue index
    private var timeObserver: Any?
    private var endObserver: AnyCancellable?

    /// Called with (ratingKey, state, timeMs, durationMs) for Plex scrobbling.
    var onTimeline: ((String, String, Int, Int) -> Void)?

    private init() {
        player.actionAtItemEnd = .advance
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
        endObserver = NotificationCenter.default
            .publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] note in
                Task { @MainActor in self?.itemDidEnd(note.object as? AVPlayerItem) }
            }
    }

    // MARK: play a set

    func play(tracks: [PlayableTrack], startAt index: Int = 0) {
        queue = tracks
        order = shuffle ? shuffledOrder(startAt: index) : Array(queue.indices)
        orderPos = shuffle ? 0 : index
        rebuildAndPlay()
    }

    func append(_ track: PlayableTrack) {
        queue.append(track)
        order.append(queue.count - 1)
        if currentIndex == nil { orderPos = 0; rebuildAndPlay() }
        else { reloadTailItems() }
    }

    func playNext(_ track: PlayableTrack) {
        queue.append(track)
        order.insert(queue.count - 1, at: min(orderPos + 1, order.count))
        if currentIndex == nil { orderPos = 0; rebuildAndPlay() } else { reloadTailItems() }
    }

    // MARK: transport

    func togglePlayPause() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        player.play(); isPlaying = true
        emitTimeline(state: "playing"); updateNowPlayingElapsed()
    }

    func pause() {
        player.pause(); isPlaying = false
        emitTimeline(state: "paused"); updateNowPlayingElapsed()
    }

    func next() {
        if repeatMode == .one { seek(to: 0); return }
        if orderPos + 1 < order.count {
            orderPos += 1; rebuildAndPlay()
        } else if repeatMode == .all {
            orderPos = 0; rebuildAndPlay()
        } else {
            emitTimeline(state: "stopped")
        }
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        guard orderPos > 0 else { seek(to: 0); return }
        orderPos -= 1; rebuildAndPlay()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        updateNowPlayingElapsed()
    }

    /// Jump to a track by its position in the user-visible queue.
    func jump(toQueueIndex index: Int) {
        guard let pos = order.firstIndex(of: index) else { return }
        orderPos = pos; rebuildAndPlay()
    }

    // MARK: queue editing

    func move(fromOffsets: IndexSet, toOffset: Int) {
        let currentKey = current?.id
        let src = fromOffsets.sorted()
        let moving = src.map { queue[$0] }
        for i in src.reversed() { queue.remove(at: i) }
        let insertAt = min(max(toOffset - src.filter { $0 < toOffset }.count, 0), queue.count)
        queue.insert(contentsOf: moving, at: insertAt)
        rebuildOrderPreservingCurrent(currentKey)
        reloadTailItems()
    }

    func remove(atQueueIndex index: Int) {
        guard queue.indices.contains(index) else { return }
        let wasCurrent = index == currentIndex
        let currentKey = current?.id
        queue.remove(at: index)
        if queue.isEmpty { stopAll(); return }
        rebuildOrderPreservingCurrent(wasCurrent ? nil : currentKey)
        if wasCurrent { rebuildAndPlay() } else { reloadTailItems() }
    }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : (repeatMode == .all ? .one : .off)
    }

    /// Update the rating the transport bar shows for the current track.
    func setCurrentRating(_ stars: Int) {
        guard let i = currentIndex else { return }
        queue[i].userRating = stars
    }

    // MARK: internals

    private func shuffledOrder(startAt index: Int) -> [Int] {
        var rest = Array(queue.indices); rest.removeAll { $0 == index }
        rest.shuffle()
        return [index] + rest
    }

    private func reshuffle() {
        guard !queue.isEmpty, let cur = currentIndex else { return }
        order = shuffle ? shuffledOrder(startAt: cur) : Array(queue.indices)
        orderPos = shuffle ? 0 : cur
        reloadTailItems()
    }

    private func rebuildOrderPreservingCurrent(_ key: String?) {
        if shuffle {
            let cur = currentIndex ?? 0
            order = shuffledOrder(startAt: min(cur, max(queue.count - 1, 0)))
            orderPos = 0
        } else {
            order = Array(queue.indices)
            orderPos = key.flatMap { k in queue.firstIndex { $0.id == k } } ?? min(orderPos, order.count - 1)
        }
    }

    /// Replace the AVQueuePlayer contents with items for order[orderPos...] and
    /// start the first one. Gapless because AVQueuePlayer preloads the tail.
    private func rebuildAndPlay() {
        guard order.indices.contains(orderPos) else { stopAll(); return }
        player.removeAllItems()
        itemTracks.removeAll()
        for pos in orderPos..<order.count {
            let qi = order[pos]
            guard queue.indices.contains(qi) else { continue }
            let item = AVPlayerItem(url: queue[qi].url)
            itemTracks[ObjectIdentifier(item)] = qi
            player.insert(item, after: nil)
        }
        currentIndex = order[orderPos]
        player.play()
        isPlaying = true
        emitTimeline(state: "playing")
        updateNowPlayingInfo()
    }

    /// Rebuild only the not-yet-played tail after the current item (used when
    /// the queue/order changes without moving the current track).
    private func reloadTailItems() {
        guard let cur = player.currentItem else { rebuildAndPlay(); return }
        for item in player.items() where item != cur { player.remove(item) }
        for pos in (orderPos + 1)..<order.count {
            let qi = order[pos]
            guard queue.indices.contains(qi) else { continue }
            let item = AVPlayerItem(url: queue[qi].url)
            itemTracks[ObjectIdentifier(item)] = qi
            player.insert(item, after: nil)
        }
    }

    private func itemDidEnd(_ item: AVPlayerItem?) {
        if repeatMode == .one { player.seek(to: .zero); player.play(); return }
        // AVQueuePlayer auto-advances; sync our pointer + metadata.
        if orderPos + 1 < order.count {
            orderPos += 1
            currentIndex = order[orderPos]
            emitTimeline(state: "playing")
            updateNowPlayingInfo()
        } else if repeatMode == .all {
            orderPos = 0; rebuildAndPlay()
        } else {
            isPlaying = false
            emitTimeline(state: "stopped")
        }
    }

    private func stopAll() {
        player.removeAllItems()
        itemTracks.removeAll()
        currentIndex = nil; order = []; orderPos = 0
        isPlaying = false; currentTime = 0; duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: timeline / scrobble

    private func emitTimeline(state: String) {
        guard let t = current else { return }
        onTimeline?(t.id, state, Int(currentTime * 1000), t.durationMs)
    }

    // MARK: system Now Playing

    private func updateNowPlayingInfo() {
        guard let t = current else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: Double(t.durationMs) / 1000.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
    }
}

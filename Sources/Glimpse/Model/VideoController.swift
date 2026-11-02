import AVFoundation

/// Plays the videos of one window.
///
/// One player serves all the videos, so the volume, the mute state and the speed stay the same from video to video.
@MainActor
final class VideoController {
    static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    /// Shorter videos always start at the beginning.
    private static let resumeMinimumDuration: Double = 60

    let player = AVPlayer()
    private(set) var url: URL?
    /// Called when the current file cannot play.
    var onFailure: (() -> Void)?

    var isLooping = Preferences.loopVideos {
        didSet { Preferences.loopVideos = isLooping }
    }

    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    /// The target of a seek that is not finished. Quick key presses add up from it.
    private var seekTarget: Double?

    init() {
        player.volume = Preferences.videoVolume
    }

    var isPlaying: Bool { player.rate != 0 }

    var duration: Double? {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return nil }
        return duration.seconds
    }

    var currentTime: Double {
        seekTarget ?? player.currentTime().seconds
    }

    // MARK: - Loading

    /// Opens a video and plays it. A long video starts where it stopped the last time.
    /// - Returns: The time where the playback starts, if it is not the beginning.
    @discardableResult
    func load(_ url: URL) -> Double? {
        close()
        let item = AVPlayerItem(url: url)
        // Keep the pitch of voices at other speeds.
        item.audioTimePitchAlgorithm = .spectral
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item, item.status == .failed else { return }
                self.onFailure?()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidPlayToEnd() }
        }
        self.url = url
        player.replaceCurrentItem(with: item)
        let resume = Preferences.playbackPosition(for: url)
        if let resume {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        return resume
    }

    /// Stops the playback and closes the file. It remembers where a long video stopped.
    func close() {
        rememberPosition()
        Preferences.videoVolume = player.volume
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        seekTarget = nil
        url = nil
        player.replaceCurrentItem(with: nil)
    }

    private func rememberPosition() {
        guard let url, let duration, duration >= Self.resumeMinimumDuration else { return }
        let time = currentTime
        // Near the start or the end, start from the beginning the next time.
        let isInMiddle = time.isFinite && time > 5 && time < duration - 10
        Preferences.setPlaybackPosition(isInMiddle ? time : nil, for: url)
    }

    private func itemDidPlayToEnd() {
        guard isLooping else { return }
        player.seek(to: .zero)
        player.play()
    }

    // MARK: - Playback

    func pause() {
        player.pause()
    }

    /// - Returns: True if the video plays now.
    func togglePlayback() -> Bool {
        guard let item = player.currentItem else { return false }
        if isPlaying {
            player.pause()
            return false
        }
        // At the end, start again from the beginning.
        if item.duration.isNumeric, CMTimeCompare(item.currentTime(), item.duration) >= 0 {
            player.seek(to: .zero)
        }
        player.play()
        return true
    }

    /// Moves the playhead by a number of seconds.
    /// - Returns: The new time, or nil if the video is not ready.
    func seek(by seconds: Double) -> Double? {
        guard let item = player.currentItem, item.status == .readyToPlay, let duration else { return nil }
        let target = min(max(currentTime + seconds, 0), duration)
        seekTarget = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                if self?.seekTarget == target { self?.seekTarget = nil }
            }
        }
        return target
    }

    /// Pauses and shows the previous or the next frame.
    func step(by frames: Int) {
        guard let item = player.currentItem, frames < 0 ? item.canStepBackward : item.canStepForward else { return }
        player.pause()
        seekTarget = nil
        item.step(byCount: frames)
    }

    /// - Returns: The new speed.
    func changeSpeed(by steps: Int) -> Float {
        let current = player.defaultRate
        let nearest = Self.speeds.indices.min { abs(Self.speeds[$0] - current) < abs(Self.speeds[$1] - current) } ?? 0
        let index = min(max(nearest + steps, 0), Self.speeds.count - 1)
        setSpeed(Self.speeds[index])
        return Self.speeds[index]
    }

    func setSpeed(_ speed: Float) {
        // `play()` uses the default rate, so the speed stays for the next videos too.
        player.defaultRate = speed
        if isPlaying { player.rate = speed }
    }

    /// - Returns: The new volume, from 0 to 1.
    func changeVolume(by delta: Float) -> Float {
        let volume = min(max(((player.volume + delta) * 10).rounded() / 10, 0), 1)
        player.volume = volume
        if delta > 0 { player.isMuted = false }
        return volume
    }

    /// The frame on the screen, at full size.
    func currentFrame() async -> CGImage? {
        guard let item = player.currentItem else { return nil }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: item.currentTime()).image
    }
}

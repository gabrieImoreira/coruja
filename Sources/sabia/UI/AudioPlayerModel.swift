import AVFoundation

/// Thin AVAudioPlayer wrapper for the notes window's inline player — play,
/// pause, scrub, and a polled currentTime (AVAudioPlayer has no publisher
/// for it). Created on the main actor, so its Timer rides NSApplication's
/// run loop like AppController's ticker does (unlike a Timer made inside a
/// plain actor — see MeetingDetector's history).
@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func load(_ url: URL) {
        stop()
        player = try? AVAudioPlayer(contentsOf: url)
        duration = player?.duration ?? 0
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func stop() {
        player?.stop()
        player = nil
        ticker?.invalidate()
        ticker = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            ticker?.invalidate()
            ticker = nil
        }
    }
}

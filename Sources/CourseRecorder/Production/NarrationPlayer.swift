import Foundation
import AVFoundation
import CoreVideo

/// Plays the narration video with its sound; the production session pulls the frames and pushes them through the
/// camera processor so the recorded presenter stands in for the live camera.
final class NarrationPlayer {
    private let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var item: AVPlayerItem?
    private var endObserver: NSObjectProtocol?
    private var loadID = UUID()
    private(set) var duration: Double = 0

    var onEnded: (() -> Void)?

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
    }

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ url: URL, completion: @escaping (Bool) -> Void) {
        let id = UUID()
        loadID = id
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        output = out
        self.item = item
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.onEnded?()
        }
        player.replaceCurrentItem(with: item)
        Task { [weak self] in
            let d = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            DispatchQueue.main.async {
                guard let self, self.loadID == id else { return }
                self.duration = d.isFinite ? d : 0
                completion(d.isFinite && d > 0)
            }
        }
    }

    func unload() {
        loadID = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        item = nil
        output = nil
        duration = 0
    }

    var currentTime: Double {
        let t = CMTimeGetSeconds(player.currentTime())
        return t.isFinite ? max(0, t) : 0
    }

    var isPlaying: Bool { player.rate > 0 }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func seek(to t: Double, completion: (() -> Void)? = nil) {
        let id = loadID
        let target = CMTime(seconds: max(0, min(duration, t)), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard finished, self?.loadID == id else { return }
                completion?()
            }
        }
    }

    /// The frame for the current playback time, if a new one is available since the last call.
    func pullFrame() -> CVPixelBuffer? {
        guard let output, let item else { return nil }
        let t = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }
}

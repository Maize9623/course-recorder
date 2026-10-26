import Foundation
import CoreVideo
import CoreGraphics
import QuartzCore

/// The latest frame of a screen or window capture.
final class ScreenFrame {
    let pixelBuffer: CVPixelBuffer
    /// Region of the buffer that contains content, in pixels with a top-left origin.
    let contentRect: CGRect
    let hostTime: CFTimeInterval

    init(pixelBuffer: CVPixelBuffer, contentRect: CGRect, hostTime: CFTimeInterval) {
        self.pixelBuffer = pixelBuffer
        self.contentRect = contentRect
        self.hostTime = hostTime
    }

    var contentSize: CGSize { contentRect.size }
}

/// Thread-safe "latest frame" slots shared by the capture threads and the render loop.
final class FrameStore {
    private let lock = NSLock()
    private var cameraFrame: CameraFrame?
    private var screens: [SourceRef: ScreenFrame] = [:]

    func setCamera(_ frame: CameraFrame?) {
        lock.lock()
        cameraFrame = frame
        lock.unlock()
    }

    func camera() -> CameraFrame? {
        lock.lock()
        defer { lock.unlock() }
        return cameraFrame
    }

    func setScreen(_ frame: ScreenFrame, for ref: SourceRef) {
        lock.lock()
        screens[ref] = frame
        lock.unlock()
    }

    func screen(_ ref: SourceRef) -> ScreenFrame? {
        lock.lock()
        defer { lock.unlock() }
        return screens[ref]
    }

    func removeScreen(_ ref: SourceRef) {
        lock.lock()
        screens[ref] = nil
        lock.unlock()
    }
}

/// Rolling frames-per-second counter.
struct FPSCounter {
    private var stamps: [CFTimeInterval] = []

    mutating func tick(_ t: CFTimeInterval = CACurrentMediaTime()) {
        stamps.append(t)
        let cutoff = t - 1
        if let i = stamps.firstIndex(where: { $0 >= cutoff }), i > 0 {
            stamps.removeFirst(i)
        }
    }

    var fps: Double {
        guard let first = stamps.first, let last = stamps.last, stamps.count > 1, last > first else { return 0 }
        return Double(stamps.count - 1) / (last - first)
    }
}

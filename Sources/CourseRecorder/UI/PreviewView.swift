import SwiftUI
import AppKit
import QuartzCore

/// Shows rendered frames by handing their IOSurface to a CALayer (zero-copy).
final class LayerSink: FrameSink {
    private weak var layer: CALayer?
    private let lock = NSLock()
    private var pending = false
    private var shown: CVPixelBuffer?

    init(layer: CALayer) {
        self.layer = layer
    }

    func consume(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
        lock.lock()
        if pending {
            lock.unlock()
            return
        }
        pending = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.layer?.contents = surface
                CATransaction.commit()
            }
            self.lock.lock()
            // Keep the buffer alive while it is on screen so the pool does not recycle it.
            self.shown = pixelBuffer
            self.pending = false
            self.lock.unlock()
        }
    }
}

final class PreviewNSView: NSView {
    let displayLayer = CALayer()
    private(set) lazy var sink = LayerSink(layer: displayLayer)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.contentsGravity = .resizeAspect
        displayLayer.magnificationFilter = .linear
        displayLayer.minificationFilter = .linear
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    override var isFlipped: Bool { true }
}

struct PreviewView: NSViewRepresentable {
    let engine: RenderEngine

    final class Coordinator {
        var engine: RenderEngine?
        var sink: LayerSink?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView(frame: .zero)
        context.coordinator.engine = engine
        context.coordinator.sink = v.sink
        engine.addSink(v.sink)
        return v
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: Coordinator) {
        if let s = coordinator.sink { coordinator.engine?.removeSink(s) }
    }
}

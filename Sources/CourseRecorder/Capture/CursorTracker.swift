import Foundation
import AppKit
import QuartzCore

struct ClickEvent {
    /// Global Quartz coordinates (points, top-left origin).
    let point: CGPoint
    let time: CFTimeInterval
}

/// Mouse position and click history, used for "follow cursor" zoom and click highlights.
final class CursorTracker {
    private let lock = NSLock()
    private var clicks: [ClickEvent] = []
    private var monitor: Any?
    var onClick: ((ClickEvent) -> Void)?

    /// Must be called on the main thread.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.recordClick()
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    /// Current cursor location in global Quartz coordinates.
    func location() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func recordClick() {
        let e = ClickEvent(point: location(), time: CACurrentMediaTime())
        lock.lock()
        clicks.append(e)
        if clicks.count > 32 { clicks.removeFirst(clicks.count - 32) }
        lock.unlock()
        onClick?(e)
    }

    func recentClicks(within seconds: Double, now: CFTimeInterval) -> [ClickEvent] {
        lock.lock()
        defer { lock.unlock() }
        return clicks.filter { now - $0.time < seconds }
    }
}

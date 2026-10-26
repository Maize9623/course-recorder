import Foundation
import QuartzCore

/// Drives the existing live compositor from narration time without writing editing actions.
final class ProductionPreview {
    private var previousTime = -1.0
    private var sources = SceneSources()

    func apply(time: Double, cues: [Cue], reset: Bool, app: AppState) {
        let rebuilding = reset || time < previousTime || previousTime < 0
        let now = CACurrentMediaTime()
        if rebuilding {
            sources = SceneSources()
            app.engine.setScene(.camera, animated: false)
            app.engine.setSlide(0, at: now - 10)
            app.engine.setPIPVisible(true, at: now - 10)
            app.engine.setZoom(false, at: now - 10)
            app.engine.hideLowerThird()
            app.scene = .camera
            app.slideIndex = 0
            app.pipHidden = false
            app.zoomed = false
        }
        for cue in cues where cue.time <= time && (rebuilding || cue.time > previousTime) {
            let instant = rebuilding || cue.time <= 0.001
            let at = instant ? now - 10 : now
            switch cue.action {
            case .scene(let scene):
                app.scene = scene
                app.engine.setScene(scene, animated: !instant, at: at)
            case .slide(let index):
                app.slideIndex = app.engine.setSlide(index, at: at)
            case .demoSource(let ref):
                sources.demo = ref
                app.engine.setSources(sources, at: at)
            case .slidesSource(let ref):
                sources.slides = ref
                app.engine.setSources(sources, at: at)
            case .pip(let visible):
                app.pipHidden = !visible
                app.engine.setPIPVisible(visible, at: at)
            case .zoom(let on):
                app.zoomed = on
                app.engine.setZoom(on, at: at)
            case .lowerThird:
                let remaining = app.settings.overlay.lowerThirdSeconds - (time - cue.time)
                if remaining > 0 { app.engine.showLowerThird(seconds: remaining, at: now) }
            }
        }
        app.engine.setSources(sources, at: rebuilding ? now - 10 : now)
        if let point = app.production.project?.cursor.last(where: { $0.t <= time }) {
            app.engine.cursorOverride = CGPoint(x: point.x, y: point.y)
        } else {
            app.engine.cursorOverride = CGPoint(x: 0.5, y: 0.5)
        }
        if !rebuilding, let clicks = app.production.project?.clicks {
            for click in clicks where click.t > previousTime && click.t <= time {
                app.engine.injectClick(CGPoint(x: click.x, y: click.y), at: now)
            }
        }
        if rebuilding { app.engine.resetAnimations() }
        previousTime = time
    }

    func reset() { previousTime = -1 }
}

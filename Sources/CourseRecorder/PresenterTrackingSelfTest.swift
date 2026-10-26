import Foundation
import CoreGraphics

/// Pure geometry checks for full-frame presenter tracking; does not create capture or GPU resources.
enum PresenterTrackingSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runCPU() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else { throw Failure(message: "出镜追踪自测失败：\(name)") }
            checks += 1
        }
        func near(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 0.0001 }
        let portrait = Canvas(width: 1080, height: 1920)
        let landscape = Canvas(width: 1920, height: 1080)
        let source = CGSize(width: 1920, height: 1080)
        func layer(_ config: LayoutConfig, face: CGPoint?, canvas: Canvas = Canvas(width: 1080, height: 1920)) -> CameraLayer {
            LayoutBuilder.layout(for: .camera, canvas: canvas, config: config, pipVisibility: 1, face: face).camera
        }
        func crop(_ camera: CameraLayer, sourceSize: CGSize = CGSize(width: 1920, height: 1080)) -> CGRect {
            cameraCrop(cameraSize: sourceSize, layerSize: camera.rect.size,
                       zoom: camera.zoom, center: camera.center, anchorX: camera.anchorX)
        }
        var config = LayoutConfig()
        config.camera.faceTracking = true
        for x in [CGFloat(0.3), 0.5, 0.7] {
            let face = CGPoint(x: x, y: 0.29)
            let camera = layer(config, face: face)
            try check(near(camera.center.x, x), "全屏出镜使用人脸水平位置")
            let region = crop(camera)
            let faceInOutput = (x * source.width - region.minX) / region.width
            try check(near(faceInOutput, 0.5), "竖屏中的离中心人脸映射到输出中央")
            try check(near(camera.center.y, 0.5), "追踪不改变垂直构图")
        }
        config.camera.fullOffsetX = 0.04
        config.camera.fullOffsetY = -0.08
        config.camera.fullZoom = 1.35
        let adjusted = layer(config, face: CGPoint(x: 0.6, y: 0.2))
        try check(near(adjusted.center.x, 0.64) && near(adjusted.center.y, 0.42), "追踪允许手动偏移叠加")
        try check(near(adjusted.zoom, 1.35), "追踪沿用手动缩放不增加数字放大")
        let missing = layer(config, face: nil)
        try check(near(missing.center.x, 0.54) && near(missing.center.y, 0.42), "初次未检测到人脸时沿用手动构图")
        config.camera.faceTracking = false
        let disabled = layer(config, face: CGPoint(x: 0.8, y: 0.15))
        try check(disabled.center == missing.center && disabled.zoom == missing.zoom, "关闭人脸跟随恢复手动构图")
        config = LayoutConfig()
        for x in [CGFloat(0.01), 0.99] {
            let region = crop(layer(config, face: CGPoint(x: x, y: 0.3)))
            try check(CGRect(origin: .zero, size: source).contains(region), "移动到边缘时裁切不越过原始画幅")
        }
        let unzoomed = layer(config, face: CGPoint(x: 0.7, y: 0.3), canvas: landscape)
        try check(near(unzoomed.zoom, 1) && crop(unzoomed) == CGRect(origin: .zero, size: source), "横屏全景不为了跟随强制放大")
        config.camera.fullZoom = 1.6
        let zoomed = layer(config, face: CGPoint(x: 0.6, y: 0.3), canvas: landscape)
        let zoomedCrop = crop(zoomed)
        try check(near((0.6 * source.width - zoomedCrop.minX) / zoomedCrop.width, 0.5), "横屏手动放大后同样可将人脸居中")

        var settings = AppSettings()
        settings.camera.fullZoom = 1.8
        settings.camera.fullOffsetX = 0.15
        settings.camera.fullOffsetY = -0.1
        var project = CourseProject(name: "合成导入口播")
        project.narrationIsImported = true
        let importedConfig = settings.layoutConfig(for: project)
        let imported = layer(importedConfig, face: CGPoint(x: 0.7, y: 0.2), canvas: portrait)
        try check(crop(imported, sourceSize: portrait.size) == portrait.bounds,
                  "导入口播已适配的完整画幅不因出镜追踪再次裁切")
        return checks
    }
}

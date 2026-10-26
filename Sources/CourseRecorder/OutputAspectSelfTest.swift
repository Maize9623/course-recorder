import Foundation
import AppKit
import AVFoundation
import CoreImage
import Metal

/// Synthetic geometry, compositor pixels and real writer/exporter checks; never captures user media.
enum OutputAspectSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runCPU() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "画幅自测失败：\(name)") }
            checks += 1
        }
        var settings = AppSettings()
        for resolution in OutputResolution.allCases {
            settings.recording.resolution = resolution
            settings.recording.aspect = .landscape
            let horizontal = settings.recording.outputSize
            let bitrate = settings.recording.videoBitrate
            try check(horizontal == resolution.size, "\(resolution.rawValue)横屏尺寸兼容")
            settings.recording.aspect = .portrait
            let vertical = settings.recording.outputSize
            try check(vertical.width == horizontal.height && vertical.height == horizontal.width, "\(resolution.rawValue)竖屏交换宽高")
            try check(settings.recording.videoBitrate == bitrate, "画幅切换保持像素量与码率")
        }
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        var recording = oldJSON["recording"] as! [String: Any]
        recording.removeValue(forKey: "aspect")
        recording["resolution"] = OutputResolution.p1440.rawValue
        oldJSON["recording"] = recording
        var demo = oldJSON["demo"] as! [String: Any]
        demo.removeValue(forKey: "portraitFraming")
        oldJSON["demo"] = demo
        var slides = oldJSON["slides"] as! [String: Any]
        slides.removeValue(forKey: "portraitFit")
        oldJSON["slides"] = slides
        var split = oldJSON["split"] as! [String: Any]
        split.removeValue(forKey: "portraitCameraAtBottom")
        split.removeValue(forKey: "portraitPersonHeight")
        split["cameraOnRight"] = false
        split["personWidth"] = 0.46
        oldJSON["split"] = split
        let migrated = SettingsStore.decode(try JSONSerialization.data(withJSONObject: oldJSON))
        try check(migrated.recording.aspect == .landscape && migrated.recording.resolution == .p1440, "旧设置补横屏默认并保留分辨率")
        try check(migrated.demo.portraitFraming == .leftHalf && migrated.slides.portraitFit == .fit, "旧设置补竖屏默认布局")
        try check(migrated.split.portraitCameraAtBottom && migrated.split.portraitPersonHeight == 0.25,
                  "旧设置补竖屏人像在下及25%高度")
        try check(!migrated.split.cameraOnRight && migrated.split.personWidth == 0.46,
                  "竖屏默认值不覆盖已存横屏分屏设置")
        let roundtrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        try check(roundtrip == settings, "新设置JSON往返")
        var project = CourseProject(name: "合成画幅")
        var projectJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
        projectJSON.removeValue(forKey: "outputAspect")
        let legacy = try JSONDecoder().decode(CourseProject.self, from: JSONSerialization.data(withJSONObject: projectJSON))
        try check(legacy.outputAspect == nil, "旧项目缺画幅仍可读取")
        project.outputAspect = .portrait
        let savedProject = try JSONDecoder().decode(CourseProject.self, from: JSONEncoder().encode(project))
        try check(savedProject.outputAspect == .portrait, "项目保存竖屏画幅")

        let canvas = Canvas(width: 1080, height: 1920)
        let horizontal = Canvas(width: 1920, height: 1080)
        try check(abs(canvas.unit - horizontal.unit) < 0.0001, "相同短边保持叠加字号")
        let horizontalPIP = LayoutBuilder.pipRect(canvas: horizontal, pip: PIPSettings())
        try check(abs(horizontalPIP.width - 364.8) < 0.0001 && abs(horizontalPIP.height - 364.8) < 0.0001,
                  "横屏默认小窗364.8像素保持原宽度比例")
        try check(abs(horizontalPIP.minX - 38.4) < 0.0001 && abs(horizontalPIP.maxY - (1080 - 38.4)) < 0.0001,
                  "横屏默认小窗38.4像素边距保持原宽度比例")
        var config = LayoutConfig()
        let defaultPortraitSplit = LayoutBuilder.layout(for: .split, canvas: canvas, config: config, pipVisibility: 1, face: nil)
        try check(abs(defaultPortraitSplit.camera.rect.minY - 1440) < 0.0001
                  && abs(defaultPortraitSplit.camera.rect.height - 480) < 0.0001
                  && abs(defaultPortraitSplit.camera.rect.maxY - 1920) < 0.0001,
                  "默认竖屏人像位于底部四分之一")
        try check(defaultPortraitSplit.content.rect.height > defaultPortraitSplit.camera.rect.height * 2,
                  "默认竖屏内容主区域明显大于人像区域")
        var changedHorizontal = config
        changedHorizontal.split.cameraOnRight = false
        changedHorizontal.split.personWidth = 0.55
        try check(LayoutBuilder.layout(for: .split, canvas: canvas, config: changedHorizontal, pipVisibility: 1, face: nil) == defaultPortraitSplit,
                  "调整横屏位置与宽度不影响竖屏布局")
        let defaultHorizontalSplit = LayoutBuilder.layout(for: .split, canvas: horizontal, config: config, pipVisibility: 1, face: nil)
        var changedPortrait = config
        changedPortrait.split.portraitCameraAtBottom = false
        changedPortrait.split.portraitPersonHeight = 0.38
        try check(LayoutBuilder.layout(for: .split, canvas: horizontal, config: changedPortrait, pipVisibility: 1, face: nil) == defaultHorizontalSplit,
                  "调整竖屏位置与高度不影响横屏布局")
        for (requested, expected) in [(0.0, 0.18), (1.0, 0.4)] {
            var limited = config
            limited.split.portraitPersonHeight = requested
            let layout = LayoutBuilder.layout(for: .split, canvas: canvas, config: limited, pipVisibility: 1, face: nil)
            try check(abs(layout.camera.rect.height / canvas.height - expected) < 0.0001,
                      "竖屏人像高度限制在18%至40%之间")
        }
        for scene in SceneKind.allCases {
            let layout = LayoutBuilder.layout(for: scene, canvas: canvas, config: config, pipVisibility: 1, face: nil)
            try check(canvas.bounds.contains(layout.camera.rect), "\(scene.rawValue)人像位于竖屏画布内")
            try check(canvas.bounds.contains(layout.content.rect), "\(scene.rawValue)内容位于竖屏画布内")
            if scene == .camera { try check(layout.camera.rect == canvas.bounds, "出镜铺满竖屏") }
            if scene == .slides { try check(layout.content.fill == 0, "竖屏讲解默认完整显示") }
            if scene == .demo { try check(layout.content.sourceCrop == CGRect(x: 0, y: 0, width: 0.5, height: 1), "演示取左半源") }
        }
        for onBottom in [true, false] {
            config.split.portraitCameraAtBottom = onBottom
            config.split.fitContent = true
            let layout = LayoutBuilder.layout(for: .split, canvas: canvas, config: config, pipVisibility: 1, face: nil)
            try check(!layout.camera.rect.intersects(layout.content.rect), "竖屏分屏内容与人像不重叠")
            try check(onBottom ? layout.camera.rect.minY >= layout.content.rect.maxY : layout.camera.rect.maxY <= layout.content.rect.minY,
                      "竖屏上下位置可互换")
            config.split.fitContent = false
            let filled = LayoutBuilder.layout(for: .split, canvas: canvas, config: config, pipVisibility: 1, face: nil)
            try check(filled.content.fill == 1 && !filled.camera.rect.intersects(filled.content.rect), "竖屏分屏铺满仍限制在内容侧")
        }
        config.presenterVisible = false
        let hidden = LayoutBuilder.layout(for: .split, canvas: canvas, config: config, pipVisibility: 1, face: nil)
        try check(hidden.camera.opacity == 0 && hidden.content.rect == canvas.bounds, "关闭人像后分屏内容展开")
        config.demo.portraitFraming = .fit
        let fit = LayoutBuilder.layout(for: .demo, canvas: canvas, config: config, pipVisibility: 1, face: nil)
        try check(fit.content.sourceCrop == CGRect(x: 0, y: 0, width: 1, height: 1) && fit.content.fill == 0, "完整演示保留全源与背景")
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let left = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        try check(Compositor.contentCrop(left, zoom: ZoomState()) == left, "无放大时精确取左半源")
        try check(Compositor.contentCrop(full, zoom: ZoomState()) == full, "横屏默认裁源不变")
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.5), CGPoint(x: 1, y: 1)] {
            let cropped = Compositor.contentCrop(left, zoom: ZoomState(factor: 1.8, center: point))
            try check(left.contains(cropped) && cropped.width > 0 && cropped.height > 0, "跟随放大限制在左半源内")
        }
        return checks
    }

    @MainActor
    static func runMedia(_ directory: URL) async throws -> Int {
        guard CommandLine.arguments.contains("--no-capture") else { throw Failure(message: "画幅媒体自测必须带 --no-capture") }
        var checks = try runCPU()
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "画幅媒体自测失败：\(name)") }
            checks += 1
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(message: "Metal不可用") }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let assets = AssetFactory(context: context)
        let folder = directory.appendingPathComponent("output-aspect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settingsBefore = try? Data(contentsOf: SettingsStore.fileURL)
        let canvas = Canvas(width: 1080, height: 1920)
        let red = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 900))
        let blue = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.9)).cropped(to: CGRect(x: 800, y: 0, width: 800, height: 900))
        let greenEdge = CIImage(color: CIColor(red: 0.1, green: 0.9, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 900))
        let source = greenEdge.composited(over: red.composited(over: blue)).cropped(to: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let compositor = Compositor(context: context, canvas: canvas)
        var config = LayoutConfig()
        config.presenterVisible = false
        config.demo.padding = 0
        config.demo.cornerRadius = 0
        config.demo.shadow = false
        var fd = FrameDescription(layout: LayoutBuilder.layout(for: .demo, canvas: canvas, config: config, pipVisibility: 0, face: nil),
                                  contents: [ContentDraw(source: .display(1))])
        let input = FrameInputs(camera: nil, contents: [.display(1): source])
        let cropped = compositor.compose(fd, input)
        let leftSize = CGSize(width: 800, height: 900)
        let rect = fd.layout.content.rect.aspectFit(leftSize)
        for p in [CGPoint(x: rect.minX + rect.width * 0.3, y: rect.midY), CGPoint(x: rect.maxX - 20, y: rect.midY)] {
            let c = pixel(cropped, at: p, canvas: canvas, context: context)
            try check(c[0] > c[2] + 100, "左半屏两侧均取红区而不含右半蓝区")
        }
        try context.writePNGRepresentation(of: cropped, to: folder.appendingPathComponent("portrait-left-half.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        fd.clicks = [ClickMark(source: .display(1), point: CGPoint(x: 0.25, y: 0.5), age: 0.2)]
        let clicked = compositor.compose(fd, input)
        let basePixel = pixel(cropped, at: rect.center, canvas: canvas, context: context)
        let clickPixel = pixel(clicked, at: rect.center, canvas: canvas, context: context)
        try check(Int(clickPixel[1]) > Int(basePixel[1]) + 10, "左半屏点击映射落在裁切后中心")
        fd.clicks = [ClickMark(source: .display(1), point: CGPoint(x: 0.75, y: 0.5), age: 0.2)]
        let excluded = compositor.compose(fd, input)
        try check(pixel(excluded, at: rect.center, canvas: canvas, context: context) == basePixel, "右半屏点击不出现在左半屏")
        config.demo.portraitFraming = .fit
        fd.layout = LayoutBuilder.layout(for: .demo, canvas: canvas, config: config, pipVisibility: 0, face: nil)
        fd.clicks = []
        let fitted = compositor.compose(fd, input)
        let fitRect = canvas.bounds.aspectFit(source.extent.size)
        let fitLeft = pixel(fitted, at: CGPoint(x: fitRect.minX + 15, y: fitRect.midY), canvas: canvas, context: context)
        let fitRight = pixel(fitted, at: CGPoint(x: fitRect.maxX - 15, y: fitRect.midY), canvas: canvas, context: context)
        try check(fitLeft[1] > fitLeft[2] + 100 && fitRight[2] > fitRight[0] + 100, "完整屏幕保留左右两端")
        try check(pixel(fitted, at: CGPoint(x: 540, y: 20), canvas: canvas, context: context)[1] > 150, "完整屏幕上下显示背景")
        try context.writePNGRepresentation(of: fitted, to: folder.appendingPathComponent("portrait-full-screen.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        fd.layout.content = ContentSlot(rect: canvas.bounds, opacity: 1, fill: 1)
        let fillBase = compositor.compose(fd, input)
        fd.clicks = [ClickMark(source: .display(1), point: CGPoint(x: 0.34, y: 0.5), age: 0.2)]
        let fillClicked = compositor.compose(fd, input)
        for x in [CGFloat(2), CGFloat(30)] {
            let p = CGPoint(x: x, y: canvas.height / 2)
            try check(pixel(fillClicked, at: p, canvas: canvas, context: context) == pixel(fillBase, at: p, canvas: canvas, context: context),
                      "铺满裁切外点击不会从画布边缘漏入")
        }

        let store = FrameStore()
        guard let screenCG = context.createCGImage(source, from: source.extent), let screenPB = SelfTest.makePixelBuffer(screenCG, ctx: context),
              let person = SelfTest.syntheticPerson(assets: assets), let cameraPB = SelfTest.makePixelBuffer(person, ctx: context) else { throw Failure(message: "无法创建合成素材") }
        store.setScreen(ScreenFrame(pixelBuffer: screenPB, contentRect: source.extent, hostTime: 0), for: .display(1))
        store.setCamera(CameraFrame(processed: cameraPB, cutout: nil, size: CGSize(width: person.width, height: person.height), face: nil, captureTime: 0))
        let engine = RenderEngine(context: context, store: store, assets: assets, cursor: CursorTracker(), canvasSize: canvas.size)
        engine.setSources(SceneSources(slides: .display(1), demo: .display(1)), at: 0)
        config.demo.portraitFraming = .leftHalf
        engine.update(config: config, transitions: TransitionSettings())
        engine.setScene(.demo, animated: false, at: 0)
        engine.cursorOverride = CGPoint(x: 0.02, y: 0.5)
        engine.setZoom(true, at: 0)
        _ = engine.renderFrame(at: 0)
        guard let zoomed = engine.renderFrame(at: 2) else { throw Failure(message: "跟随放大无帧") }
        let zoomImage = CIImage(cvPixelBuffer: zoomed)
        let zoomEdge = pixel(zoomImage, at: CGPoint(x: rect.minX + 25, y: rect.midY), canvas: canvas, context: context)
        try check(zoomEdge[1] > zoomEdge[0] + 100, "鼠标靠左放大仍显示左边缘标记")
        try context.writePNGRepresentation(of: zoomImage, to: folder.appendingPathComponent("portrait-zoom-left-edge.png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        engine.setZoom(false, at: 0)
        engine.cursorOverride = nil
        config.presenterVisible = true
        engine.update(config: config, transitions: TransitionSettings())
        let movie = folder.appendingPathComponent("portrait-four-scenes.mp4")
        try await writeMovie(movie, engine: engine, context: context, folder: folder)
        let asset = AVURLAsset(url: movie)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try check(video.count == 1 && audio.count == 1, "竖屏真实writer包含音视频轨")
        let naturalSize = try await video[0].load(.naturalSize)
        try check(naturalSize == canvas.size, "竖屏真实writer尺寸1080×1920")
        let videoDuration = try await video[0].load(.timeRange).duration.seconds
        let audioDuration = try await audio[0].load(.timeRange).duration.seconds
        try check(abs(videoDuration - 4) < 0.001 && abs(videoDuration - audioDuration) < 0.002, "四镜头短片音视频均4秒")
        var project = CourseProject(name: "合成竖屏导出")
        project.outputAspect = .portrait
        project.narrationFile = movie.lastPathComponent
        project.narrationDuration = 4
        project.narrationIsImported = true
        project.includeBGM = false
        project.cues = SceneKind.allCases.enumerated().map { Cue(time: Double($0.offset), action: .scene($0.element)) }
        project.cues += [Cue(time: 0, action: .slidesSource(.display(1))), Cue(time: 0, action: .demoSource(.display(1)))]
        project.takes = [Take(file: movie.lastPathComponent, source: .display(1), start: 0, end: 4,
                              width: 1080, height: 1920, contentRect: canvas.bounds)]
        var exportSettings = AppSettings()
        exportSettings.recording.aspect = .landscape
        exportSettings.recording.resolution = .p1080
        exportSettings.recording.fps = 30
        exportSettings.camera.faceTracking = false
        exportSettings.background.mode = .off
        exportSettings.beauty.enabled = false
        exportSettings.bgm.tracks = []
        exportSettings.bgm.monitor = false
        exportSettings.demo.portraitFraming = .fit
        let exporter = ProjectExporter(project: project, folder: folder, settings: exportSettings, assets: assets, context: context)
        let exported: Result<URL, Error> = await withCheckedContinuation { continuation in
            exporter.run(progress: { _ in }, completion: { continuation.resume(returning: $0) })
        }
        let exportedURL = try exported.get()
        let exportedAsset = AVURLAsset(url: exportedURL)
        let exportedVideo = try await exportedAsset.loadTracks(withMediaType: .video)
        let exportedAudio = try await exportedAsset.loadTracks(withMediaType: .audio)
        try check(exportedVideo.count == 1 && exportedAudio.count == 1, "竖屏项目离线导出含音视频")
        let exportedSize = try await exportedVideo[0].load(.naturalSize)
        let exportedVideoDuration = try await exportedVideo[0].load(.timeRange).duration.seconds
        let exportedAudioDuration = try await exportedAudio[0].load(.timeRange).duration.seconds
        try check(exportedSize == canvas.size, "离线导出遵守项目竖屏而非全局横屏")
        try check(abs(exportedVideoDuration - 4) < 0.001 && abs(exportedAudioDuration - 4) < 0.002, "竖屏项目离线成片音视频均4秒")
        try check((try? Data(contentsOf: SettingsStore.fileURL)) == settingsBefore, "媒体测试未改变个人设置")
        try "Output aspect: \(checks) checks passed\nmovie: \(movie.path)\n".write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("output aspect artifacts: \(folder.path)")
        return checks
    }

    private static func pixel(_ image: CIImage, at point: CGPoint, canvas: Canvas, context: CIContext) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        let bounds = CGRect(x: point.x.rounded(.down), y: (canvas.height - point.y - 1).rounded(.down), width: 1, height: 1)
        rgba.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4, bounds: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        return rgba
    }

    private static func writeMovie(_ url: URL, engine: RenderEngine, context: CIContext, folder: URL) async throws {
        let recorder = Recorder()
        try recorder.start(RecorderOptions(url: url, size: engine.canvas.size, fps: 30, codec: .h264, bitrate: 10_000_000, offline: true))
        let mixer = AudioMixer()
        mixer.trustsTimestamps = true
        var mix = MixerConfig()
        mix.highPass = false; mix.gate = false; mix.avOffset = 0
        mixer.update(mix)
        mixer.onMixed = { recorder.appendAudio($0) }
        var videoIndex = 0, audioIndex = 0
        var audioFinished = false
        var tone = [Float](repeating: 0, count: 1600)
        for sample in tone.indices {
            let phase = Double(sample) * 2.0 * Double.pi * 300.0 / 48_000.0
            tone[sample] = Float(sin(phase) * 0.12)
        }
        let deadline = CACurrentMediaTime() + 90
        while videoIndex < 120 || audioIndex < 120 {
            guard CACurrentMediaTime() < deadline else { throw Failure(message: "竖屏短片writer超时") }
            let ready = recorder.inputReadiness
            var fed = false
            if videoIndex < 120, ready.video {
                let t = Double(videoIndex) / 30
                if videoIndex % 30 == 0 { engine.setScene(SceneKind.allCases[videoIndex / 30], animated: false, at: t) }
                guard let pb = engine.renderFrame(at: t) else { throw Failure(message: "竖屏合成无帧") }
                recorder.consume(pb, hostTime: t)
                if videoIndex % 30 == 0 {
                    try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: pb), to: folder.appendingPathComponent("portrait-\(SceneKind.allCases[videoIndex / 30].rawValue).png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
                videoIndex += 1
                fed = true
            }
            if audioIndex < 120, ready.audio {
                tone.withUnsafeBufferPointer { mixer.processMic($0.baseAddress!, frames: 1600, pts: Double(audioIndex) / 30) }
                audioIndex += 1
                fed = true
            }
            if audioIndex == 120, !audioFinished { recorder.finishAudioInput(); audioFinished = true }
            if !fed { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        let result: RecordingResult = await withCheckedContinuation { continuation in recorder.stop(markers: []) { continuation.resume(returning: $0) } }
        guard result.files == [url], result.failedSegments.isEmpty, result.error == nil, recorder.currentStats().framesWritten == 120 else {
            throw result.error ?? Failure(message: "竖屏短片未完整保存120帧")
        }
    }
}

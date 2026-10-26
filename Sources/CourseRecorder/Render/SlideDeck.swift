import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Imported slides: a PDF (exported from Keynote / PowerPoint), a single image, or a folder of images.
final class SlideDeck {
    private enum Kind {
        case pdf(CGPDFDocument)
        case images([URL])
    }

    let path: String
    let pageCount: Int
    let title: String
    private let kind: Kind
    private let lock = NSLock()
    private var cache: [Int: CIImage] = [:]
    private var pending: Set<Int> = []
    private var cacheSize: CGSize = .zero
    private let queue = DispatchQueue(label: "slides.render", qos: .userInitiated)
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `title` overrides the display name, e.g. the original .pptx for a converted PDF.
    init?(path: String, title displayTitle: String? = nil) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        self.path = path
        if isDir.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let images = files.filter { f in
                guard let t = UTType(filenameExtension: f.pathExtension) else { return false }
                return t.conforms(to: .image)
            }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            guard !images.isEmpty else { return nil }
            kind = .images(images)
            pageCount = images.count
        } else if url.pathExtension.lowercased() == "pdf" {
            guard let doc = CGPDFDocument(url as CFURL), doc.numberOfPages > 0 else { return nil }
            kind = .pdf(doc)
            pageCount = doc.numberOfPages
        } else {
            guard let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .image) else { return nil }
            kind = .images([url])
            pageCount = 1
        }
        title = displayTitle ?? url.lastPathComponent
    }

    /// Returns the page if it is rendered, otherwise schedules rendering and returns the closest cached page.
    func image(at index: Int, size: CGSize) -> CIImage? {
        let i = max(0, min(pageCount - 1, index))
        lock.lock()
        if cacheSize != size {
            cache.removeAll()
            pending.removeAll()
            cacheSize = size
        }
        if let img = cache[i] {
            lock.unlock()
            return img
        }
        let fallback = cache.min(by: { abs($0.key - i) < abs($1.key - i) })?.value
        lock.unlock()
        prefetch(around: i, size: size)
        return fallback
    }

    func prefetch(around index: Int, size: CGSize) {
        for i in [index, index + 1, index - 1, index + 2] where i >= 0 && i < pageCount {
            lock.lock()
            let need = cache[i] == nil && !pending.contains(i)
            if need { pending.insert(i) }
            lock.unlock()
            guard need else { continue }
            queue.async { [weak self] in
                guard let self else { return }
                let img = self.render(i, size: size).map { CIImage(cgImage: $0) }
                self.lock.lock()
                self.pending.remove(i)
                if self.cacheSize == size, let img {
                    self.cache[i] = img
                    // Keep memory bounded: high-resolution pages are large, so keep only the neighbours.
                    if self.cache.count > 5 {
                        for k in self.cache.keys where abs(k - i) > 2 { self.cache[k] = nil }
                    }
                }
                self.lock.unlock()
            }
        }
    }

    /// Small preview of a page for the slide strip (synchronous, not cached).
    func thumbnail(_ index: Int, size: CGSize) -> CGImage? {
        render(index, size: size, highRes: false)
    }

    /// Pixel size to render a page at: enough for "fill" on the canvas plus zoom headroom, capped at ~12 MP.
    private func renderSize(page: CGSize, canvas: CGSize, highRes: Bool) -> CGSize {
        let bounds = CGRect(origin: .zero, size: canvas)
        let fit = bounds.aspectFit(page)
        guard highRes else { return fit.size }
        let fill = bounds.aspectFill(page)
        var target = CGSize(width: fill.width * 1.25, height: fill.height * 1.25)
        let maxPixels: CGFloat = 12_000_000
        let pixels = target.width * target.height
        if pixels > maxPixels {
            let k = (maxPixels / pixels).squareRoot()
            target = CGSize(width: target.width * k, height: target.height * k)
        }
        if target.width < fit.width { target = fit.size }
        return CGSize(width: target.width.rounded(), height: target.height.rounded())
    }

    /// Synchronous render, used by tests and for the first page.
    func renderNow(_ index: Int, size: CGSize) -> CIImage? {
        guard let cg = render(index, size: size) else { return nil }
        let img = CIImage(cgImage: cg)
        lock.lock()
        if cacheSize != size {
            cache.removeAll()
            cacheSize = size
        }
        cache[index] = img
        lock.unlock()
        return img
    }

    /// Renders a page at its own aspect ratio.
    private func render(_ index: Int, size: CGSize, highRes: Bool = true) -> CGImage? {
        switch kind {
        case .pdf(let doc):
            guard let page = doc.page(at: index + 1) else { return nil }
            let box = page.getBoxRect(.cropBox)
            let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
            let rotated = angle == 90 || angle == 270
            let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
            let target = renderSize(page: pageSize, canvas: size, highRes: highRes)
            let w = max(1, Int(target.width.rounded())), h = max(1, Int(target.height.rounded()))
            guard let ctx = makeContext(w, h) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let s = CGFloat(w) / max(1, pageSize.width)
            ctx.scaleBy(x: s, y: s)
            ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(page)
            return ctx.makeImage()
        case .images(let urls):
            guard index < urls.count,
                  let src = CGImageSourceCreateWithURL(urls[index] as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            let native = CGSize(width: img.width, height: img.height)
            var target = renderSize(page: native, canvas: size, highRes: highRes)
            // Never upscale bitmaps beyond their own resolution.
            if target.width > native.width { target = native }
            let w = max(1, Int(target.width.rounded())), h = max(1, Int(target.height.rounded()))
            guard let ctx = makeContext(w, h) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
    }

    private func makeContext(_ w: Int, _ h: Int) -> CGContext? {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .high
        return ctx
    }
}

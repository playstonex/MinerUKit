import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - PDF / image raster helpers (internal to the pipeline)

extension CGPDFDocument {
    static func open(_ url: URL) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(url as CFURL) else {
            throw MinerUKit.Error.cannotOpenPDF(url.path)
        }
        return doc
    }
}

/// Renders a PDF page at `scale` into an opaque RGB CGImage.
/// CGBitmapContext and PDF page user space are both y-up: no flip needed.
/// The resulting image is top-left origin, matching MinerU box coordinates.
func renderPage(_ page: CGPDFPage, scale: CGFloat) -> CGImage? {
    let box = page.getBoxRect(.mediaBox)
    let w = Int((box.width * scale).rounded())
    let h = Int((box.height * scale).rounded())
    guard w > 0, h > 0 else { return nil }
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
    guard let ctx else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(page)
    return ctx.makeImage()
}

/// Squashes the page into the fixed square layout-grid input.
func resizedLayout(_ image: CGImage, size: Int) -> CGImage? {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
    guard let ctx else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()
}

/// Crops a normalized (0–1, top-left origin) box. Upstream MinerU adds no
/// padding; `pad` stays available for callers that want a safety margin.
func renderCrop(_ image: CGImage, box: LayoutParser.Box, pad: Double = 0) -> CGImage? {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let x = max(0, (box.x1 - pad) * w).rounded(.down), y = max(0, (box.y1 - pad) * h).rounded(.down)
    let cw = min(w, ((box.x2 + pad) * w).rounded(.up)) - x
    let ch = min(h, ((box.y2 + pad) * h).rounded(.up)) - y
    guard cw >= 1, ch >= 1 else { return nil }
    return image.cropping(to: CGRect(x: x, y: y, width: cw, height: ch))
}

/// Upstream `resize_by_need`: strips with an extreme aspect ratio are padded
/// with white to at most `maxEdgeRatio`:1, and crops whose short edge is
/// below `minEdge` are enlarged so the vision tower sees real detail.
func prepareRegion(_ image: CGImage, minEdge: Int = 28, maxEdgeRatio: Double = 50) -> CGImage {
    var current = image
    let w = Double(current.width), h = Double(current.height)
    if max(w, h) / min(w, h) > maxEdgeRatio {
        let newW = w > h ? w : (h / maxEdgeRatio).rounded(.up)
        let newH = w > h ? (w / maxEdgeRatio).rounded(.up) : h
        if let padded = whiteCanvas(current, width: Int(newW), height: Int(newH), scale: 1) {
            current = padded
        }
    }
    let shortEdge = min(current.width, current.height)
    if shortEdge < minEdge {
        let scale = Double(minEdge) / Double(shortEdge)
        let newW = Int((Double(current.width) * scale).rounded(.up))
        let newH = Int((Double(current.height) * scale).rounded(.up))
        if let scaled = whiteCanvas(current, width: newW, height: newH, scale: scale) {
            current = scaled
        }
    }
    return current
}

/// Draws `image` centered on a white canvas; `scale` stretches it (1 = as is).
private func whiteCanvas(_ image: CGImage, width: Int, height: Int, scale: Double) -> CGImage? {
    guard width > 0, height > 0 else { return nil }
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
    guard let ctx else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.interpolationQuality = .high
    let dw = Double(image.width) * scale, dh = Double(image.height) * scale
    ctx.draw(image, in: CGRect(
        x: (Double(width) - dw) / 2, y: (Double(height) - dh) / 2, width: dw, height: dh
    ))
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, name: String) throws -> URL {
    try writePNG(image, to: FileManager.default.temporaryDirectory, name: name)
}

func writePNG(_ image: CGImage, to directory: URL, name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw MinerUKit.Error.cannotWriteImage(url.path)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw MinerUKit.Error.cannotWriteImage(url.path)
    }
    return url
}

extension CGImage {
    /// Rotates counter-clockwise by a multiple of 90° (same sense as PIL's
    /// `Image.rotate(angle, expand=True)`), swapping width and height for
    /// odd quarter turns.
    func rotated(by degrees: CGFloat) throws -> CGImage {
        let quarterTurns = ((Int((degrees / 90).rounded()) % 4) + 4) % 4
        if quarterTurns == 0 { return self }
        let w = CGFloat(width), h = CGFloat(height)
        let swap = quarterTurns % 2 == 1
        // Bitmap contexts are y-up, so these are plain counter-clockwise maps.
        let transform: CGAffineTransform
        switch quarterTurns {
        case 1: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        default: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        }
        let ctx = CGContext(
            data: nil, width: swap ? height : width, height: swap ? width : height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        guard let ctx else {
            throw MinerUKit.Error.cannotWriteImage("rotating region crop")
        }
        ctx.concatenate(transform)
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rotated = ctx.makeImage() else {
            throw MinerUKit.Error.cannotWriteImage("rotating region crop")
        }
        return rotated
    }
}

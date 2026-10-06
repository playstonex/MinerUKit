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

/// Crops a normalized (0–1, top-left origin) box with a small padding.
func renderCrop(_ image: CGImage, box: LayoutParser.Box, pad: Double = 0.005) -> CGImage? {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let x = max(0, (box.x1 - pad) * w), y = max(0, (box.y1 - pad) * h)
    let cw = min(w, (box.x2 + pad) * w) - x, ch = min(h, (box.y2 + pad) * h) - y
    guard cw >= 8, ch >= 8 else { return nil }
    return image.cropping(to: CGRect(x: x, y: y, width: cw, height: ch))
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
    func rotated(by degrees: CGFloat) throws -> CGImage {
        let radians = degrees * .pi / 180
        var extent = CGRect(x: 0, y: 0, width: width, height: height)
        extent = extent.applying(CGAffineTransform(rotationAngle: radians))
        var transform = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        transform = transform.concatenating(CGAffineTransform(rotationAngle: radians))
        let ctx = CGContext(
            data: nil, width: Int(extent.width.rounded()), height: Int(extent.height.rounded()),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        guard let ctx else {
            throw MinerUKit.Error.cannotWriteImage("rotating region crop")
        }
        ctx.concatenate(transform)
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard let rotated = ctx.makeImage() else {
            throw MinerUKit.Error.cannotWriteImage("rotating region crop")
        }
        return rotated
    }
}

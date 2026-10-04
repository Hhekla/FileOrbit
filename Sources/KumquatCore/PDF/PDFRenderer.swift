import CoreGraphics
import Foundation
import PDFKit

public enum PDFRenderer {
    /// CoreGraphics renders page streams but omits annotation appearances, including
    /// filled form fields. Use PDFKit for pages with visible annotations.
    public static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        guard let raw = page.pageRef else { return nil }
        guard page.annotations.contains(where: \.shouldDisplay) else { return render(raw, dpi: dpi) }
        guard dpi.isFinite, dpi > 0, dpi <= 1200 else { return nil }
        let box = raw.getBoxRect(.cropBox)
        let rotation = ((Int(raw.rotationAngle) % 360) + 360) % 360
        let scale = dpi / 72
        let width = ((rotation == 90 || rotation == 270 ? box.height : box.width) * scale).rounded()
        let height = ((rotation == 90 || rotation == 270 ? box.width : box.height) * scale).rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 32_768, height <= 32_768, width * height <= 100_000_000 else { return nil }
        let thumbnail = page.thumbnail(of: CGSize(width: width, height: height), for: .cropBox)
        return thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Rasterizes a page at the given DPI on a white background, honouring /Rotate.
    public static func render(_ page: CGPDFPage, dpi: Double) -> CGImage? {
        guard dpi.isFinite, dpi > 0, dpi <= 1200 else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.minX.isFinite, box.minY.isFinite,
              box.width > 0, box.height > 0 else { return nil }
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let scale = CGFloat(dpi / 72)
        var size = box.size
        if rotation == 90 || rotation == 270 { size = CGSize(width: size.height, height: size.width) }
        let width = (size.width * scale).rounded(), height = (size.height * scale).rounded()
        guard width.isFinite, height.isFinite, width <= 32_768, height <= 32_768,
              width * height <= 100_000_000 else { return nil }
        let pixelWidth = max(1, Int(width))
        let pixelHeight = max(1, Int(height))
        guard
              let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: ImageIOHelpers.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.defaultIntent)
        ctx.scaleBy(x: CGFloat(pixelWidth) / size.width, y: CGFloat(pixelHeight) / size.height)
        ctx.concatenate(displayTransform(box: box, rotation: rotation))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    /// Maps page space (the crop box) to an upright, origin-at-zero space of the displayed size.
    public static func displayTransform(box: CGRect, rotation: Int) -> CGAffineTransform {
        let w = box.width, h = box.height
        var t: CGAffineTransform
        switch rotation {
        case 90:
            // Displayed rotated clockwise: page left edge becomes the top edge.
            t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180:
            t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270:
            t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default:
            t = .identity
        }
        return CGAffineTransform(translationX: -box.minX, y: -box.minY).concatenating(t)
    }

    public static func document(at url: URL) throws -> CGPDFDocument {
        guard let doc = CGPDFDocument(url as CFURL) else { throw KumquatError.decodeFailed(url.lastPathComponent) }
        if doc.isEncrypted && !doc.unlockWithPassword("") {
            throw KumquatError.processFailed("\(url.lastPathComponent) is password protected.")
        }
        return doc
    }
}

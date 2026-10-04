import AppKit
import ImageIO
import UniformTypeIdentifiers
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let color = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 60, y: 60, width: 904, height: 904), cornerWidth: 212, cornerHeight: 212, transform: nil))
        ctx.setFillColor(CGColor(red: 0.05, green: 0.31, blue: 0.28, alpha: 1)); ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 0.55, green: 0.83, blue: 0.66, alpha: 1)); ctx.setLineWidth(34)
        ctx.strokeEllipse(in: CGRect(x: 172, y: 276, width: 680, height: 472))
        ctx.saveGState(); ctx.translateBy(x: 512, y: 512); ctx.rotate(by: .pi / 3)
        ctx.strokeEllipse(in: CGRect(x: -340, y: -236, width: 680, height: 472)); ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: CGRect(x: 364, y: 320, width: 296, height: 384), cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.87, alpha: 1)); ctx.fillPath()
        ctx.setStrokeColor(CGColor(red: 0.10, green: 0.40, blue: 0.34, alpha: 1)); ctx.setLineWidth(28); ctx.setLineCap(.round)
        for y in [432, 512, 592] { ctx.move(to: CGPoint(x: 425, y: y)); ctx.addLine(to: CGPoint(x: 598, y: y)); ctx.strokePath() }
        ctx.setFillColor(CGColor(red: 0.97, green: 0.75, blue: 0.36, alpha: 1)); ctx.fillEllipse(in: CGRect(x: 748, y: 480, width: 108, height: 108))
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        let dest = CGImageDestinationCreateWithURL(folder.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { fatalError("Unable to write icon") }
    }
}

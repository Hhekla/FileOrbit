import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Image tools with explicit output semantics. Resize fits inside the requested bounds while
/// preserving aspect ratio; target size changes encoding, never pixels or transparency.
public enum ImageOperations {
    private static let maximumPixels = 64_000_000

    public static func run(_ tool: ToolKind, inputs: [URL], parameters: ToolParameters,
                           capabilities: Capabilities) async throws -> [URL] {
        guard !inputs.isEmpty else { throw KumquatError.nothingToDo("Choose at least one image.") }
        if tool == .collage { return [try collage(inputs, parameters: parameters)] }
        var outputs: [URL] = []
        for input in inputs {
            try Task.checkCancellation()
            try ImageIOHelpers.requireSingleFrame(input)
            switch tool {
            case .resize:
                let image = try ImageIOHelpers.loadImage(input)
                let size = try fittedSize(width: image.width, height: image.height,
                                          boundsWidth: parameters.width, boundsHeight: parameters.height)
                let resized = try draw(width: size.0, height: size.1) { context in
                    context.draw(image, in: CGRect(x: 0, y: 0, width: size.0, height: size.1))
                }
                outputs.append(try savePNG(resized, input: input, tag: "Resized"))
            case .qrCode:
                let image = try ImageIOHelpers.loadImage(input)
                let payloads = try qrPayloads(in: image)
                guard !payloads.isEmpty else { throw KumquatError.nothingToDo("No readable QR code was found in \(input.lastPathComponent).") }
                let destination = OutputNaming.taggedURL(for: input, tag: "QR Codes", ext: "txt")
                outputs.append(try OutputNaming.write(to: destination) {
                    try (payloads.joined(separator: "\n\n") + "\n").write(to: $0, atomically: true, encoding: .utf8)
                })
            case .targetSize:
                outputs.append(try targetSize(input, megabytes: parameters.targetMegabytes))
            default:
                throw KumquatError.unsupportedConversion(from: "Image", to: tool.title)
            }
        }
        return outputs
    }

    /// A zero dimension means unconstrained. Both positive dimensions define a bounding box.
    static func fittedSize(width: Int, height: Int, boundsWidth: Int, boundsHeight: Int) throws -> (Int, Int) {
        guard width > 0, height > 0, boundsWidth >= 0, boundsHeight >= 0,
              boundsWidth <= 16_384, boundsHeight <= 16_384,
              boundsWidth > 0 || boundsHeight > 0 else {
            throw KumquatError.processFailed("Use a width or height between 1 and 16,384 pixels; zero leaves that dimension unconstrained.")
        }
        let x = boundsWidth > 0 ? Double(boundsWidth) / Double(width) : Double.infinity
        let y = boundsHeight > 0 ? Double(boundsHeight) / Double(height) : Double.infinity
        let ratio = min(x, y)
        let w = max(1, Int((Double(width) * ratio).rounded()))
        let h = max(1, Int((Double(height) * ratio).rounded()))
        try validateCanvas(width: w, height: h)
        return (w, h)
    }

    private static func collage(_ inputs: [URL], parameters: ToolParameters) throws -> URL {
        guard inputs.count >= 2, inputs.count <= 64 else {
            throw KumquatError.processFailed("A collage needs 2 to 64 single-frame images.")
        }
        guard parameters.columns > 0, parameters.columns <= 16,
              parameters.padding >= 0, parameters.padding <= 1_024,
              parameters.width > 0, parameters.width <= 16_384,
              parameters.height > 0, parameters.height <= 16_384 else {
            throw KumquatError.processFailed("Use 1–16 columns, 0–1,024 pixels of padding, and positive cell dimensions up to 16,384 pixels.")
        }
        let columns = min(parameters.columns, inputs.count)
        let rows = (inputs.count + columns - 1) / columns
        let cellW = parameters.width, cellH = parameters.height, padding = parameters.padding
        let width = columns * cellW + (columns + 1) * padding
        let height = rows * cellH + (rows + 1) * padding
        try validateCanvas(width: width, height: height)
        // Read all sources before starting a destination so an unreadable image can't make a
        // collage with a silently missing cell. Downsample each input to the requested cell.
        let images = try inputs.map { input -> CGImage in
            try ImageIOHelpers.requireSingleFrame(input)
            return try ImageIOHelpers.loadImage(input, maxPixelSize: max(cellW, cellH))
        }
        let combined = try draw(width: width, height: height) { context in
            for (index, image) in images.enumerated() {
                let scale = min(Double(cellW) / Double(image.width), Double(cellH) / Double(image.height))
                let w = Double(image.width) * scale, h = Double(image.height) * scale
                let column = index % columns, row = index / columns
                let x = Double(padding + column * (cellW + padding)) + (Double(cellW) - w) / 2
                // First item is the upper-left cell; CoreGraphics' canvas starts bottom-left.
                let y = Double(height - padding - (row + 1) * cellH - row * padding) + (Double(cellH) - h) / 2
                context.draw(image, in: CGRect(x: x, y: y, width: w, height: h))
            }
        }
        return try savePNG(combined, input: inputs[0], tag: "Collage")
    }

    static func qrPayloads(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.03 {
                return $0.boundingBox.midY > $1.boundingBox.midY
            }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var seen = Set<String>()
        return observations.compactMap { observation in
            guard let value = observation.payloadStringValue, !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func targetSize(_ input: URL, megabytes: Double) throws -> URL {
        guard megabytes.isFinite, megabytes > 0, megabytes <= 1_000 else {
            throw KumquatError.processFailed("Target size must be greater than zero and at most 1,000 MB (1 MB = 1,000,000 bytes).")
        }
        let budget = Int(megabytes * 1_000_000)
        guard budget > 0 else { throw KumquatError.processFailed("The target is smaller than one byte.") }
        let image = try ImageIOHelpers.loadImage(input)
        try validateCanvas(width: image.width, height: image.height)
        var candidates: [(Data, String)] = []
        if ImageIOHelpers.hasTransparency(image) {
            // Preserve transparency and dimensions. Do not flatten an alpha image just to hit
            // a byte budget, and do not call a lossy alpha conversion "lossless".
            candidates.append((try ImageIOHelpers.encode(image, type: .png), "png"))
            guard let pixels = RGBABuffer(image: image) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
            candidates.append((try VP8LEncoder.encode(pixels), "webp"))
        } else {
            let opaque = ImageIOHelpers.flatten(image)
            // Encode and measure real bytes; quality values are not file-size estimates.
            for quality in [1.0, 0.95, 0.9, 0.85, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.05] {
                let data = try ImageIOHelpers.encode(opaque, type: .jpeg,
                    properties: [kCGImageDestinationLossyCompressionQuality: quality])
                candidates = [(data, "jpg")]
                if data.count <= budget { break }
            }
        }
        guard let candidate = candidates.filter({ $0.0.count <= budget }).min(by: { $0.0.count < $1.0.count }) else {
            let measured = candidates.map { $0.0.count }.min() ?? 0
            throw KumquatError.processFailed("Cannot reach \(budget) bytes while preserving pixel dimensions and transparency. Smallest attempted encoding: \(measured) bytes. No output was created; the original is unchanged.")
        }
        let destination = OutputNaming.taggedURL(for: input, tag: "Target Size", ext: candidate.1)
        return try OutputNaming.write(to: destination) { try candidate.0.write(to: $0) }
    }

    private static func validateCanvas(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= maximumPixels / height else {
            throw KumquatError.processFailed("The requested image exceeds 16,384 pixels per side or 64 million pixels in total.")
        }
    }

    private static func draw(width: Int, height: Int, body: (CGContext) -> Void) throws -> CGImage {
        try validateCanvas(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: ImageIOHelpers.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw KumquatError.encodeFailed("image canvas")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        body(context)
        guard let image = context.makeImage() else { throw KumquatError.encodeFailed("image canvas") }
        return image
    }

    private static func savePNG(_ image: CGImage, input: URL, tag: String) throws -> URL {
        try OutputNaming.write(to: OutputNaming.taggedURL(for: input, tag: tag, ext: "png")) {
            try ImageIOHelpers.write(image, to: $0, type: .png)
        }
    }
}

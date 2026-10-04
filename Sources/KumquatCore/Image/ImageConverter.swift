import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ImageConverter {
    public static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions,
                               capabilities: Capabilities) async throws -> [URL] {
        try ImageIOHelpers.requireRasterInput(input)
        try rejectUnsupportedAPNGPoster(input)
        if format == .svg {
            throw KumquatError.processFailed("SVG vectorization is not supported. No SVG was written; embedding a bitmap would not create vector artwork.")
        }
        let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
        if ["tif", "tiff"].contains(input.pathExtension.lowercased()),
           CGImageSourceGetCount(try ImageIOHelpers.source(input)) > 1,
           ![OutputFormat.pdf, .docx].contains(format) {
            throw KumquatError.processFailed("多页 TIFF 不能转换为只保留第一页的图片。请转换为 PDF 或 DOCX 以保留全部页面；未生成缺页文件。")
        }
        // ImageIO advertises EXR but cannot decode every valid floating-point EXR.
        // Use FFmpeg's decoder when available, retaining 16-bit RGBA for the
        // intermediate raster instead of failing all offered targets outright.
        if input.pathExtension.lowercased() == "exr",
           (try? ImageIOHelpers.loadImage(input)) == nil,
           let ffmpeg = capabilities.ffmpegURL {
            return [try await OutputNaming.write(to: destination) { out in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FileOrbit-exr-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = directory.appendingPathComponent("decoded.png")
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path,
                                                            "-frames:v", "1", "-pix_fmt", "rgba64be", png.path])
                let converted = try await convert(png, to: format, options: options, capabilities: capabilities)
                guard let result = converted.first else { throw KumquatError.encodeFailed(input.lastPathComponent) }
                try FileManager.default.copyItem(at: result, to: out)
            }]
        }
        switch format {
        case .jpg, .png, .heic, .tiff, .bmp, .gif:
            return [try OutputNaming.write(to: destination) { try writeImageIO(input, to: $0, format: format, options: options) }]
        case .avif:
            if capabilities.canWriteAVIF {
                return [try OutputNaming.write(to: destination) { try writeImageIO(input, to: $0, format: .avif, options: options) }]
            }
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.toolMissing("ffmpeg") }
            // The SVT-AV1 fallback only accepts opaque YUV420. Dropping alpha here
            // produces a valid-looking file with black/changed transparent regions.
            guard !ImageIOHelpers.hasTransparency(try ImageIOHelpers.loadImage(input)) else {
                throw KumquatError.processFailed("当前 AVIF 编码器无法保留透明区域。请改用 PNG 或 WebP；未生成丢失透明度的文件。")
            }
            return [try await OutputNaming.write(to: destination) { out in
                try await withTemporaryPNG(of: input) { png in
                    try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", png.path,
                                                                "-frames:v", "1", "-c:v", "libsvtav1", "-crf", "30",
                                                                "-pix_fmt", "yuv420p", out.path])
                }
            }]
        case .webp:
            return [try await OutputNaming.write(to: destination) { out in
                try await writeWebP(input, to: out, options: options, capabilities: capabilities)
            }]
        case .pdf:
            return [try OutputNaming.write(to: destination) { try writePDF(images: [input], to: $0, quality: options.imageQuality) }]
        case .docx:
            return [try OutputNaming.write(to: destination) { try writeDocx(input, to: $0, options: options) }]
        case .mp4:
            return [try await OutputNaming.write(to: destination) { try await AnimatedImageVideo.writeMP4(from: input, to: $0) }]
        default:
            throw KumquatError.unsupportedConversion(from: input.pathExtension.uppercased(), to: format.title)
        }
    }

    /// On the supported macOS decoder, an APNG with a separate default poster
    /// can return the final animation frame for every index. Refuse that variant
    /// instead of publishing a valid file containing the wrong picture/animation.
    static func rejectUnsupportedAPNGPoster(_ input: URL) throws {
        guard ["png", "apng"].contains(input.pathExtension.lowercased()) else { return }
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return }
        var animated = false
        var firstFrameControl = false
        while let header = try handle.read(upToCount: 8), header.count == 8 {
            let bytes = [UInt8](header)
            let length = bytes.prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let kind = String(bytes: bytes.suffix(4), encoding: .ascii)
            if kind == "acTL" { animated = true }
            if kind == "fcTL" { firstFrameControl = true }
            if kind == "IDAT" {
                if animated && !firstFrameControl {
                    throw KumquatError.processFailed("此 APNG 含独立封面，当前系统解码器无法正确读取动画画面。请先导出为普通 PNG 或 GIF；未生成画面错误的文件。")
                }
                return
            }
            if kind == "IEND" { return }
            try handle.seek(toOffset: handle.offset() + length + 4)
        }
    }

    // MARK: - ImageIO formats

    static func writeImageIO(_ input: URL, to output: URL, format: OutputFormat, options: ConversionOptions) throws {
        let src = try ImageIOHelpers.source(input)
        let props = ImageIOHelpers.properties(src)
        let type = ImageIOHelpers.utType(for: format)
        let frameCount = CGImageSourceGetCount(src)

        // Animated sources keep their animation when the target is GIF.
        if format == .gif && frameCount > 1 {
            try writeAnimatedGIF(from: src, to: output)
            return
        }

        // Lossy targets re-encode straight from the source, keeping EXIF, GPS and orientation.
        // (TIFF goes through the decoded path: ImageIO ignores LZW compression when copying from a source.)
        let keepsOrientationTag = [.jpg, .heic, .avif].contains(format)
        let opaqueOnly = format == .jpg || format == .bmp
        let sourceHasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        var destProps: [CFString: Any] = [:]
        if [.jpg, .heic, .avif].contains(format) {
            destProps[kCGImageDestinationLossyCompressionQuality] = options.imageQuality
        }

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        if keepsOrientationTag && !(opaqueOnly && sourceHasAlpha) {
            // Re-encodes from the source and keeps EXIF/GPS/orientation.
            CGImageDestinationAddImageFromSource(dest, src, 0, destProps as CFDictionary)
        } else {
            var image = try ImageIOHelpers.loadImage(from: src, name: input.lastPathComponent)
            if opaqueOnly && ImageIOHelpers.hasAlpha(image) {
                image = ImageIOHelpers.flatten(image)
            }
            if format != .bmp && format != .gif {
                destProps.merge(ImageIOHelpers.portableMetadata(props, keepOrientation: false)) { a, _ in a }
            }
            if format == .tiff { ImageIOHelpers.applyLZW(&destProps) }
            CGImageDestinationAddImage(dest, image, destProps as CFDictionary)
        }
        if CGImageDestinationFinalize(dest) { return }
        guard keepsOrientationTag && !(opaqueOnly && sourceHasAlpha) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        // Some RAW containers decode successfully but cannot be copied through
        // AddImageFromSource (for example Nikon scanner NEF). Retry only that
        // failed path from full-size decoded pixels, preserving their color space.
        var decoded = try ImageIOHelpers.loadImage(from: src, name: input.lastPathComponent)
        if opaqueOnly && ImageIOHelpers.hasAlpha(decoded) { decoded = ImageIOHelpers.flatten(decoded) }
        var retryProperties = ImageIOHelpers.portableMetadata(props, keepOrientation: false)
        retryProperties[kCGImageDestinationLossyCompressionQuality] = options.imageQuality
        guard let retry = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        CGImageDestinationAddImage(retry, decoded, retryProperties as CFDictionary)
        guard CGImageDestinationFinalize(retry) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
    }

    static func writeAnimatedGIF(from src: CGImageSource, to output: URL) throws {
        let count = CGImageSourceGetCount(src)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            let delay = frameDelay(ImageIOHelpers.properties(src, index: i))
            CGImageDestinationAddImage(dest, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
    }

    /// Frame duration from whichever animation dictionary the source format uses.
    static func frameDelay(_ props: [CFString: Any]) -> Double {
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dict, unclamped, clamped) in dictionaries {
            if let d = props[dict] as? [CFString: Any] {
                let value = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
                if value > 0 { return value }
            }
        }
        return 0.1
    }

    // MARK: - WebP

    static func writeWebP(_ input: URL, to output: URL, options: ConversionOptions, capabilities: Capabilities) async throws {
        let source = try ImageIOHelpers.source(input)
        let frameCount = CGImageSourceGetCount(source)
        // Icon containers store alternative resolutions, not an animation timeline.
        // Treat their selected image just like the other still-image output paths.
        let isIconContainer = ["ico", "icns"].contains(input.pathExtension.lowercased())
        if frameCount > 1 && !isIconContainer {
            guard ["gif", "png", "apng"].contains(input.pathExtension.lowercased()) else {
                throw KumquatError.processFailed("Multi-frame \(input.pathExtension.uppercased()) to WebP is not supported without discarding frames. No output was created.")
            }
            // Homebrew's webp package ships gif2webp alongside cwebp. It preserves GIF
            // disposal, timing and loop semantics directly, including transparent frames.
            let hasVeryShortFrames = (0..<frameCount).contains {
                frameDelay(ImageIOHelpers.properties(source, index: $0)) < 0.02
            }
            // gif2webp applies browser-style delay normalization to 10 ms GIFs.
            // Our frame mux path preserves their literal timing instead.
            if input.pathExtension.lowercased() == "gif", !hasVeryShortFrames,
               let cwebp = capabilities.cwebpURL {
                let converter = cwebp.deletingLastPathComponent().appendingPathComponent("gif2webp")
                if FileManager.default.isExecutableFile(atPath: converter.path) {
                    try await ExternalTools.runChecked(converter, ["-quiet", "-mt", input.path, "-o", output.path])
                    try validateAnimation(output, against: source)
                    return
                }
            }
            let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
            let gif = fileProperties[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
            let png = fileProperties[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
            let loopCount: Int
            if input.pathExtension.lowercased() == "gif" {
                // ImageIO has already translated GIF's stored repetition count
                // into total plays (raw 1 -> property 2), matching WebP's field.
                // Adding one again would make the mux fallback loop once too often.
                if let plays = (gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue {
                    loopCount = min(65_535, plays)
                } else { loopCount = 1 }
            } else {
                loopCount = (png[kCGImagePropertyAPNGLoopCount] as? NSNumber)?.intValue ?? 1
            }
            if let cwebp = capabilities.cwebpURL {
                let mux = cwebp.deletingLastPathComponent().appendingPathComponent("webpmux")
                if FileManager.default.isExecutableFile(atPath: mux.path) {
                    try await writeAnimationWithWebPMux(source, to: output, cwebp: cwebp, mux: mux,
                                                       loopCount: loopCount)
                    try validateAnimation(output, against: source)
                    return
                }
            }
            guard let ffmpeg = capabilities.ffmpegURL else {
                throw KumquatError.processFailed("Animated WebP conversion needs gif2webp, cwebp with webpmux, or FFmpeg with libwebp_anim. The original animation was preserved; no still-image substitute was created.")
            }
            // Lossless RGBA preserves alpha and avoids introducing halos between animation frames.
            try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path,
                "-map", "0:v:0", "-an", "-c:v", "libwebp_anim", "-lossless", "1", "-pix_fmt", "bgra",
                "-fps_mode", "passthrough", "-loop", String(loopCount), output.path])
            try validateAnimation(output, against: source)
            return
        }
        let image = try ImageIOHelpers.loadImage(input)
        let lossless = options.webpLossless || ImageIOHelpers.hasTransparency(image)
        if let cwebp = capabilities.cwebpURL {
            try await withTemporaryPNG(of: input) { png in
                var arguments = ["-quiet", "-mt"]
                if lossless { arguments += ["-lossless", "-exact"] }
                else { arguments += ["-q", String(Int(min(100, max(0, options.webpQuality))))] }
                arguments += ["-metadata", "icc", png.path, "-o", output.path]
                try await ExternalTools.runChecked(cwebp, arguments)
            }
            return
        }
        try encodeWebP(image, to: output, lossless: lossless, quality: options.webpQuality / 100)
    }

    /// ImageIO supplies composited full-canvas APNG frames. Encoding each one as a
    /// lossless WebP avoids depending on an optional FFmpeg libwebp_anim build.
    private static func writeAnimationWithWebPMux(_ source: CGImageSource, to output: URL,
                                                 cwebp: URL, mux: URL, loopCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOrbit-animation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var arguments: [String] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw KumquatError.decodeFailed("Animation frame \(index + 1)")
            }
            let png = directory.appendingPathComponent("frame-\(index).png")
            let webp = directory.appendingPathComponent("frame-\(index).webp")
            try ImageIOHelpers.write(frame, to: png, type: .png)
            try await ExternalTools.runChecked(cwebp, ["-quiet", "-mt", "-lossless", "-exact",
                                                       png.path, "-o", webp.path])
            let milliseconds = max(1, Int((frameDelay(ImageIOHelpers.properties(source, index: index)) * 1000).rounded()))
            // Replace each full canvas; blending would accumulate semi-transparent pixels.
            arguments += ["-frame", webp.path, "+\(milliseconds)+0+0+0-b"]
        }
        arguments += ["-loop", String(loopCount), "-bgcolor", "0,0,0,0", "-o", output.path]
        try await ExternalTools.runChecked(mux, arguments)
    }

    private static func validateAnimation(_ output: URL, against source: CGImageSource) throws {
        let encoded = try ImageIOHelpers.source(output)
        let count = CGImageSourceGetCount(source)
        guard CGImageSourceGetCount(encoded) == count else {
            throw KumquatError.encodeFailed("Animated WebP: the output frame count does not match the original")
        }
        for index in 0..<count {
            let before = frameDelay(ImageIOHelpers.properties(source, index: index))
            let after = frameDelay(ImageIOHelpers.properties(encoded, index: index))
            // WebP stores integer milliseconds. Allow rounding, not an entire
            // 20 ms frame: the latter hid doubled durations for fast APNG input.
            guard abs(before - after) < 0.0011 else {
                throw KumquatError.encodeFailed("Animated WebP: frame timing could not be preserved")
            }
        }
    }

    /// Kumquat's own WebP encoders: lossy VP8 for opaque pictures, lossless VP8L when asked
    /// for or when the image has transparency.
    public static func encodeWebP(_ image: CGImage, to output: URL, lossless: Bool, quality: Double) throws {
        guard let buffer = RGBABuffer(image: image) else { throw KumquatError.decodeFailed("image") }
        let data: Data
        if lossless || buffer.hasTransparency {
            data = try VP8LEncoder.encode(buffer)
        } else {
            data = try VP8Encoder.encode(buffer, quality: quality)
        }
        try data.write(to: output)
    }

    public static func encodeWebPLossless(_ image: CGImage, to output: URL) throws {
        try encodeWebP(image, to: output, lossless: true, quality: 1)
    }

    /// Writes an upright PNG copy of the image to a temporary file for command-line encoders.
    static func withTemporaryPNG(of input: URL, _ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrbit-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Preserve the encoder work directory for inspection; never recursively remove it.
        let png = dir.appendingPathComponent("input.png")
        let image = try ImageIOHelpers.loadImage(input)
        try ImageIOHelpers.write(image, to: png, type: .png)
        try await body(png)
    }

    // MARK: - PDF

    /// One page per image. Page size follows the image's DPI (like Preview), capped at A4.
    /// Opaque images are embedded as JPEG so the PDF stays close to the original size.
    public static func writePDF(images: [URL], to output: URL, quality: Double) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw KumquatError.encodeFailed(output.lastPathComponent) }
        for url in images {
            try rejectUnsupportedAPNGPoster(url)
            let src = try ImageIOHelpers.source(url)
            let count = ["tif", "tiff"].contains(url.pathExtension.lowercased()) ? CGImageSourceGetCount(src) : 1
            for index in 0..<count {
                let props = ImageIOHelpers.properties(src, index: index)
                let image = try loadPage(src, index: index, name: url.lastPathComponent)
                let dpi = max(72, (props[kCGImagePropertyDPIWidth] as? Double) ?? 72)
                var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
                // Camera photos claim 72 dpi, which would make 40-inch pages. Keep pages at most
                // A4-sized; the pixels are untouched, they just print at a higher resolution.
                let longest = max(box.width, box.height)
                if longest > 842 {
                    box.size = CGSize(width: box.width * 842 / longest, height: box.height * 842 / longest)
                }
                let drawable = pdfDrawableImage(image, quality: quality) ?? image
                ctx.beginPage(mediaBox: &box)
                ctx.interpolationQuality = .high
                ctx.draw(drawable, in: box)
                ctx.endPage()
            }
        }
        ctx.closePDF()
    }

    private static func loadPage(_ source: CGImageSource, index: Int, name: String) throws -> CGImage {
        if index == 0 { return try ImageIOHelpers.loadImage(from: source, name: name) }
        let props = ImageIOHelpers.properties(source, index: index)
        if ImageIOHelpers.orientation(props) == .up,
           let image = CGImageSourceCreateImageAtIndex(source, index, nil) { return image }
        let size = ImageIOHelpers.pixelSize(props)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw KumquatError.decodeFailed("\(name), page \(index + 1)")
        }
        return image
    }

    static func pdfDrawableImage(_ image: CGImage, quality: Double) -> CGImage? {
        guard !ImageIOHelpers.hasTransparency(image),
              let jpeg = try? ImageIOHelpers.encode(ImageIOHelpers.flatten(image), type: .jpeg,
                                                   properties: [kCGImageDestinationLossyCompressionQuality: quality]),
              let provider = CGDataProvider(data: jpeg as CFData)
        else { return nil }
        // Quartz passes JPEG data straight into the PDF when the image is backed by it.
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - DOCX

    /// The picture itself, followed by any text recognized in it (editable in Word/Pages).
    static func writeDocx(_ input: URL, to output: URL, options: ConversionOptions,
                          recognizer: (CGImage, [String]) throws -> [String] = {
                              try TextRecognizer.recognizeText(in: $0, languages: $1)
                          }) throws {
        try rejectUnsupportedAPNGPoster(input)
        let source = try? ImageIOHelpers.source(input)
        let count = ["tif", "tiff"].contains(input.pathExtension.lowercased()) ? source.map(CGImageSourceGetCount) ?? 1 : 1
        var doc = DocxDocument(title: OutputNaming.baseName(of: input))
        for index in 0..<count {
            if index > 0 { doc.appendPageBreak() }
            let image = try source.map { try loadPage($0, index: index, name: input.lastPathComponent) }
                ?? ImageIOHelpers.loadImage(input)
            let embedded = try embeddableImageData(image)
            doc.append(DocxImage.fitted(data: embedded.data, fileExtension: embedded.ext,
                                        pixelWidth: image.width, pixelHeight: image.height,
                                        maxWidth: doc.textWidth, maxHeight: doc.textHeight * 0.9))
            let ocrImage = downscaled(image, maxPixel: 4096)
            let paragraphs = try recognizer(ocrImage, options.recognitionLanguages)
            for text in paragraphs {
                doc.append(DocxParagraph(text))
            }
        }
        try DocxWriter.write(doc, to: output)
    }

    static func embeddableImageData(_ image: CGImage) throws -> (data: Data, ext: String) {
        if ImageIOHelpers.hasTransparency(image) {
            return (try ImageIOHelpers.encode(image, type: .png), "png")
        }
        return (try ImageIOHelpers.encode(ImageIOHelpers.flatten(image), type: .jpeg,
                                          properties: [kCGImageDestinationLossyCompressionQuality: 0.9]), "jpeg")
    }

    public static func downscaled(_ image: CGImage, maxPixel: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}

import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import KumquatCore

final class ImageRegressionTests: XCTestCase {
    private var directory: URL!
    private let native = Capabilities(canWriteHEIC: false, canWriteAVIF: false, ffmpegURL: nil, cwebpURL: nil)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOrbit-image-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Fixtures and outputs intentionally remain for inspection; no bulk cleanup.
    }

    private func image(width: Int = 64, height: Int = 32, alpha: Bool = true) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x % 256)
                bytes[i + 1] = UInt8(y % 256)
                bytes[i + 2] = 140
                bytes[i + 3] = alpha && x < width / 2 ? 0 : 255
            }
        }
        return try XCTUnwrap(RGBABuffer(width: width, height: height, pixels: bytes).makeImage())
    }

    private func png(_ name: String = "input.png", width: Int = 64, height: Int = 32, alpha: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ImageIOHelpers.write(image(width: width, height: height, alpha: alpha), to: url, type: .png)
        return url
    }

    private func animatedGIF() throws -> URL {
        let url = directory.appendingPathComponent("animation.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary)
        for (width, delay) in [(32, 0.12), (32, 0.28)] {
            let frame = try image(width: width, height: 32, alpha: delay < 0.2)
            CGImageDestinationAddImage(destination, frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testTransparentAVIFFallbackRefusesToDropAlpha() async throws {
        let input = try png(width: 96, height: 64)
        let original = try Data(contentsOf: input)
        // If the alpha guard regresses, this deliberately unusable encoder makes
        // the test fail with a different error before any output can be published.
        let capabilities = Capabilities(canWriteHEIC: false, canWriteAVIF: false,
                                        ffmpegURL: URL(fileURLWithPath: "/usr/bin/false"), cwebpURL: nil)
        do {
            _ = try await ImageConverter.convert(input, to: .avif, options: ConversionOptions(), capabilities: capabilities)
            XCTFail("The AVIF fallback cannot silently discard transparency")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("透明"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("PNG") && error.localizedDescription.contains("WebP"))
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("input.avif").path))
    }

    func testOpaqueAVIFFallbackStillEncodesARealImage() async throws {
        guard let ffmpeg = Capabilities.detect().ffmpegURL else { throw XCTSkip("FFmpeg unavailable") }
        let input = try png(width: 96, height: 64, alpha: false)
        let capabilities = Capabilities(canWriteHEIC: false, canWriteAVIF: false, ffmpegURL: ffmpeg, cwebpURL: nil)
        let urls = try await ImageConverter.convert(input, to: .avif, options: ConversionOptions(), capabilities: capabilities)
        let decoded = try ImageIOHelpers.loadImage(XCTUnwrap(urls.first))
        XCTAssertEqual(decoded.width, 96)
        XCTAssertEqual(decoded.height, 64)
        XCTAssertFalse(ImageIOHelpers.hasTransparency(decoded))
    }

    func testResizeKeepsAspectAndTransparency() async throws {
        let input = try png(width: 120, height: 60)
        let original = try Data(contentsOf: input)
        var parameters = ToolParameters(); parameters.width = 40; parameters.height = 40
        let result = try await ImageOperations.run(.resize, inputs: [input], parameters: parameters, capabilities: native)
        let resized = try ImageIOHelpers.loadImage(XCTUnwrap(result.first))
        XCTAssertEqual(resized.width, 40)
        XCTAssertEqual(resized.height, 20)
        XCTAssertTrue(ImageIOHelpers.hasTransparency(resized))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testCollageDimensionsAndEmptyCellsStayTransparent() async throws {
        let inputs = try [png("one.png"), png("two.png"), png("three.png")]
        var parameters = ToolParameters(); parameters.width = 80; parameters.height = 50
        parameters.columns = 2; parameters.padding = 10
        let output = try await ImageOperations.run(.collage, inputs: inputs, parameters: parameters, capabilities: native)
        let result = try ImageIOHelpers.loadImage(XCTUnwrap(output.first))
        XCTAssertEqual(result.width, 190)
        XCTAssertEqual(result.height, 130)
        XCTAssertTrue(ImageIOHelpers.hasTransparency(result))
    }

    func testTargetSizeChecksRealBytesAndPreservesPixels() async throws {
        let input = try png(width: 200, height: 100, alpha: false)
        var parameters = ToolParameters(); parameters.targetMegabytes = 0.005
        let output = try await ImageOperations.run(.targetSize, inputs: [input], parameters: parameters, capabilities: native)
        let url = try XCTUnwrap(output.first)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 5_000)
        let result = try ImageIOHelpers.loadImage(url)
        XCTAssertEqual(result.width, 200); XCTAssertEqual(result.height, 100)
    }

    func testImpossibleTargetFailsWithoutClaimingSuccessOrChangingOriginal() async throws {
        let input = try png()
        let original = try Data(contentsOf: input)
        var parameters = ToolParameters(); parameters.targetMegabytes = 0.000001
        do {
            _ = try await ImageOperations.run(.targetSize, inputs: [input], parameters: parameters, capabilities: native)
            XCTFail("A one-byte target cannot contain an image")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Cannot reach"), error.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["input.png"])
    }

    func testAnimatedWebPWithoutFFmpegFailsInsteadOfDroppingFrames() async throws {
        let input = try animatedGIF()
        do {
            _ = try await ImageConverter.convert(input, to: .webp, options: ConversionOptions(), capabilities: native)
            XCTFail("Animation must not be silently converted to a still")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Animated WebP"), error.localizedDescription)
        }
        XCTAssertEqual(CGImageSourceGetCount(try ImageIOHelpers.source(input)), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("animation.webp").path))
    }

    func testAnimatedWebPWithAvailableEncoderKeepsFramesAndDurations() async throws {
        let capabilities = Capabilities.detect()
        guard capabilities.ffmpegURL != nil || capabilities.cwebpURL != nil else { throw XCTSkip("An external WebP encoder is unavailable") }
        let input = try animatedGIF()
        let urls = try await ImageConverter.convert(input, to: .webp, options: ConversionOptions(), capabilities: capabilities)
        let source = try ImageIOHelpers.source(XCTUnwrap(urls.first))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertEqual(ImageConverter.frameDelay(ImageIOHelpers.properties(source, index: 0)), 0.12, accuracy: 0.025)
        XCTAssertEqual(ImageConverter.frameDelay(ImageIOHelpers.properties(source, index: 1)), 0.28, accuracy: 0.025)
    }

    func testAPNGKeepsAlphaFramesTimingAndLoopWithoutFFmpeg() async throws {
        guard let cwebp = Capabilities.detect().cwebpURL,
              FileManager.default.isExecutableFile(atPath: cwebp.deletingLastPathComponent().appendingPathComponent("webpmux").path)
        else { throw XCTSkip("cwebp/webpmux unavailable") }
        let input = directory.appendingPathComponent("animation.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 3]] as CFDictionary)
        for (index, delay) in [0.2, 0.4].enumerated() {
            CGImageDestinationAddImage(destination, try image(width: 32, height: 32, alpha: index == 0),
                [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let capabilities = Capabilities(canWriteHEIC: false, canWriteAVIF: false, ffmpegURL: nil, cwebpURL: cwebp)
        let urls = try await ImageConverter.convert(input, to: .webp, options: ConversionOptions(), capabilities: capabilities)
        let before = try ImageIOHelpers.source(input)
        let after = try ImageIOHelpers.source(XCTUnwrap(urls.first))
        XCTAssertEqual(CGImageSourceGetCount(after), 2)
        for index in 0..<2 {
            XCTAssertEqual(ImageConverter.frameDelay(ImageIOHelpers.properties(after, index: index)), [0.2, 0.4][index], accuracy: 0.001)
            let beforeImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(before, index, nil))
            let afterImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(after, index, nil))
            XCTAssertEqual(try XCTUnwrap(RGBABuffer(image: beforeImage)).pixels,
                           try XCTUnwrap(RGBABuffer(image: afterImage)).pixels)
        }
        let properties = CGImageSourceCopyProperties(after, nil) as? [CFString: Any]
        let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        XCTAssertEqual((webp?[kCGImagePropertyWebPLoopCount] as? NSNumber)?.intValue, 3)
    }

    func testIconResolutionsAreNotMisclassifiedAsAnimation() async throws {
        let input = directory.appendingPathComponent("resolutions.icns")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.icns.identifier as CFString, 2, nil))
        for size in [32, 128] {
            CGImageDestinationAddImage(destination, try image(width: size, height: size, alpha: true), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertGreaterThan(CGImageSourceGetCount(try ImageIOHelpers.source(input)), 1)
        let expected = try ImageIOHelpers.loadImage(input)
        let urls = try await ImageConverter.convert(input, to: .webp, options: ConversionOptions(), capabilities: native)
        let result = try ImageIOHelpers.loadImage(XCTUnwrap(urls.first))
        XCTAssertEqual(result.width, expected.width)
        XCTAssertEqual(result.height, expected.height)
        XCTAssertEqual(try XCTUnwrap(RGBABuffer(image: result)).pixels,
                       try XCTUnwrap(RGBABuffer(image: expected)).pixels)
    }

    func testFastAPNGAndGIFPreserveTenMillisecondFramesInActualWebPChunks() async throws {
        guard let cwebp = Capabilities.detect().cwebpURL,
              FileManager.default.isExecutableFile(atPath: cwebp.deletingLastPathComponent().appendingPathComponent("webpmux").path)
        else { throw XCTSkip("cwebp/webpmux unavailable") }
        for gif in [false, true] {
            let input = directory.appendingPathComponent(gif ? "fast-animation.gif" : "fast-animation.png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, (gif ? UTType.gif : UTType.png).identifier as CFString, 2, nil))
            CGImageDestinationSetProperties(destination, [gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary: [gif ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount: 3]] as CFDictionary)
            for index in 0..<2 {
                CGImageDestinationAddImage(destination, try image(width: 32, height: 32, alpha: index == 0),
                    [gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary: [gif ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime: 0.01]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let capabilities = Capabilities(canWriteHEIC: false, canWriteAVIF: false, ffmpegURL: nil, cwebpURL: cwebp)
            let urls = try await ImageConverter.convert(input, to: .webp, options: ConversionOptions(), capabilities: capabilities)
            // Read RIFF/ANMF duration bytes directly: using frameDelay here could
            // repeat the converter's own clamping mistake and falsely pass the test.
            let bytes = [UInt8](try Data(contentsOf: XCTUnwrap(urls.first)))
            var offset = 12
            var milliseconds: [Int] = []
            var totalPlays: Int?
            while offset + 8 <= bytes.count {
                let size = (0..<4).reduce(0) { $0 | (Int(bytes[offset + 4 + $1]) << (8 * $1)) }
                guard size <= bytes.count - offset - 8 else { break }
                if Array(bytes[offset..<(offset + 4)]) == Array("ANMF".utf8), size >= 16 {
                    let durationOffset = offset + 8 + 12
                    milliseconds.append((0..<3).reduce(0) { $0 | (Int(bytes[durationOffset + $1]) << (8 * $1)) })
                }
                if Array(bytes[offset..<(offset + 4)]) == Array("ANIM".utf8), size >= 6 {
                    totalPlays = Int(bytes[offset + 12]) | (Int(bytes[offset + 13]) << 8)
                }
                offset += 8 + size + size % 2
            }
            XCTAssertEqual(milliseconds, [10, 10])
            XCTAssertEqual(totalPlays, 3)
        }
    }

    func testMultipageTIFFKeepsEveryPageInPDFAndDOCX() async throws {
        let input = directory.appendingPathComponent("pages.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        for width in [32, 64] {
            CGImageDestinationAddImage(destination, try image(width: width, height: 32, alpha: false), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pdfURLs = try await ImageConverter.convert(input, to: .pdf, options: ConversionOptions(), capabilities: native)
        let pdf = try XCTUnwrap(PDFDocument(url: XCTUnwrap(pdfURLs.first)))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).width, 32, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(pdf.page(at: 1)).bounds(for: .mediaBox).width, 64, accuracy: 0.1)

        let docx = directory.appendingPathComponent("pages.docx")
        var widths: [Int] = []
        try ImageConverter.writeDocx(input, to: docx, options: ConversionOptions(), recognizer: { image, _ in
            widths.append(image.width)
            return ["Page width \(image.width)"]
        })
        XCTAssertEqual(widths, [32, 64])
        let archive = try Data(contentsOf: docx)
        XCTAssertNotNil(archive.range(of: Data("word/media/image2.jpeg".utf8)))

        do {
            _ = try await ImageConverter.convert(input, to: .png, options: ConversionOptions(), capabilities: native)
            XCTFail("A multipage TIFF must not report success with a first-page-only PNG")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("多页 TIFF"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pages.png").path))
    }

    func testAPNGWithSeparatePosterRefusesIncorrectSystemDecodedFrames() async throws {
        // Genuine 32×32 APNG: red default poster, then green 200 ms and blue
        // 400 ms animation frames, three plays. Generated with Pillow's
        // default_image=True; its IDAT precedes the first fcTL.
        let fixture = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAACGFjVEwAAAACAAAAA2qEwsoAAAAzSURBVHic7dBBDQAACAOxgX/PEFTw6Qzc0ppk8rj+jDtAgAABAgQIECBAgAABAgQInMACMOMCPvG9+cIAAAAaZmNUTAAAAAAAAAAgAAAAIAAAAAAAAAAAAAEABQAAkXtk1wAAADdmZEFUAAAAAXic7dBBDQAACAOxgX/PEFTw6Qzc0spk8rj+jDtAgAABAgQIECBAgAABAgQInMACL+QCPi0ipWIAAAAaZmNUTAAAAAIAAAAgAAAAIAAAAAAAAAAAAAIABQAAO03N7gAAADdmZEFUAAAAA3ic7dBBDQAACAOxgX/PEFTw6Qzc0kpm8rj+jDtAgAABAgQIECBAgAABAgQInMACLuUCPrBJDvAAAAAASUVORK5CYII="
        let input = directory.appendingPathComponent("poster.png")
        let data = try XCTUnwrap(Data(base64Encoded: fixture))
        try data.write(to: input)
        for format in [OutputFormat.webp, .jpg, .pdf, .docx] {
            do {
                _ = try await ImageConverter.convert(input, to: format, options: ConversionOptions(), capabilities: native)
                XCTFail("Separate APNG poster must not become the wrong frame")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("独立封面"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("poster.\(format.fileExtension)").path))
        }
        XCTAssertEqual(try Data(contentsOf: input), data)
    }

    func testEXRDecodingFallbackProducesVisiblePixels() async throws {
        guard let ffmpeg = Capabilities.detect().ffmpegURL else { throw XCTSkip("FFmpeg unavailable") }
        let original = try png("original.png", width: 64, height: 32, alpha: false)
        let exr = directory.appendingPathComponent("float.exr")
        try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", original.path,
                                                    "-pix_fmt", "gbrpf32le", "-format", "float", exr.path])
        let capabilities = Capabilities(canWriteHEIC: false, canWriteAVIF: false, ffmpegURL: ffmpeg, cwebpURL: nil)
        let urls = try await ImageConverter.convert(exr, to: .png, options: ConversionOptions(), capabilities: capabilities)
        let result = try ImageIOHelpers.loadImage(XCTUnwrap(urls.first))
        XCTAssertEqual(result.width, 64)
        XCTAssertEqual(result.height, 32)
        let before = try XCTUnwrap(RGBABuffer(image: ImageIOHelpers.loadImage(original)))
        let after = try XCTUnwrap(RGBABuffer(image: result))
        // FFmpeg's EXR encoder stores these channel values as linear RGB.
        // The original PNG is tagged sRGB, so comparing its bytes directly with
        // color-managed output would falsely reject the correct transfer curve.
        let expected = before.pixels.enumerated().map { index, byte -> Double in
            guard index % 4 != 3 else { return Double(byte) }
            let linear = Double(byte) / 255
            return 255 * (linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055)
        }
        let error = zip(expected, after.pixels).reduce(0.0) { $0 + abs($1.0 - Double($1.1)) }
        XCTAssertLessThan(error / Double(before.pixels.count), 2)
    }

    func testAnimatedCompressionRefusesFrameLoss() async throws {
        let input = try animatedGIF()
        do {
            _ = try await ImageCompressor.compress(input, quality: 0.6, capabilities: native)
            XCTFail("Compress must not select only the first frame")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("multiple frames"), error.localizedDescription)
        }
    }

    func testTransparentWebPIsActuallyLosslessWithCwebp() async throws {
        let capabilities = Capabilities.detect()
        guard capabilities.cwebpURL != nil else { throw XCTSkip("cwebp is unavailable") }
        let input = try png()
        var options = ConversionOptions(); options.webpLossless = true; options.webpQuality = 5
        let urls = try await ImageConverter.convert(input, to: .webp, options: options, capabilities: capabilities)
        let url = try XCTUnwrap(urls.first)
        let bytes = try Data(contentsOf: url)
        XCTAssertNotNil(bytes.range(of: Data("VP8L".utf8)), "The file must contain a lossless VP8L payload")
        let expected = try XCTUnwrap(RGBABuffer(image: ImageIOHelpers.loadImage(input)))
        let actual = try XCTUnwrap(RGBABuffer(image: ImageIOHelpers.loadImage(url)))
        XCTAssertEqual(actual.pixels, expected.pixels)
        XCTAssertTrue(actual.hasTransparency)
    }

    func testTransparentWebPUsesLosslessEvenWithLowQualityPreference() async throws {
        let input = try png()
        var options = ConversionOptions(); options.webpLossless = false; options.webpQuality = 5
        for capabilities in [native, Capabilities.detect()] {
            let urls = try await ImageConverter.convert(input, to: .webp, options: options, capabilities: capabilities)
            let url = try XCTUnwrap(urls.first)
            let bytes = try Data(contentsOf: url)
            XCTAssertNotNil(bytes.range(of: Data("VP8L".utf8)))
            let expected = try XCTUnwrap(RGBABuffer(image: ImageIOHelpers.loadImage(input)))
            let actual = try XCTUnwrap(RGBABuffer(image: ImageIOHelpers.loadImage(url)))
            XCTAssertEqual(actual.pixels, expected.pixels)
        }
    }

    func testOCRFailureDoesNotWriteSuccessfulImageOnlyDocx() throws {
        enum FixtureFailure: Error { case unavailable }
        let input = try png()
        let output = directory.appendingPathComponent("output.docx")
        XCTAssertThrowsError(try ImageConverter.writeDocx(input, to: output, options: ConversionOptions(), recognizer: { _, _ in
            throw FixtureFailure.unavailable
        })) { XCTAssertTrue($0 is FixtureFailure) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSVGIsExplicitlyUnsupportedNotPretendVectorization() async throws {
        let input = try png()
        do {
            _ = try await ImageConverter.convert(input, to: .svg, options: ConversionOptions(), capabilities: native)
            XCTFail("Raster embedding is not vectorization")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("vectorization"), error.localizedDescription)
        }
        let svg = directory.appendingPathComponent("shape.svg")
        try "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>".write(to: svg, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ImageIOHelpers.loadImage(svg))
    }

    func testQRCodePayloadIsSavedAsText() async throws {
        let payload = "https://example.org/fileorbit-test"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let qr = try XCTUnwrap(context.createCGImage(output, from: output.extent))
        let input = directory.appendingPathComponent("qr.png")
        try ImageIOHelpers.write(qr, to: input, type: .png)
        let urls = try await ImageOperations.run(.qrCode, inputs: [input], parameters: ToolParameters(), capabilities: native)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(urls.first), encoding: .utf8), payload + "\n")
    }
}

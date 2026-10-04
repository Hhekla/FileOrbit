import CoreGraphics
import CoreImage
import ImageIO
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

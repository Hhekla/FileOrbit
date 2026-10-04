import AppKit
import CoreText
import PDFKit
import XCTest
@testable import KumquatCore

/// Retain synthetic fixtures so a DOCX can also be inspected in a real document reader.
/// No personal documents are used, and no fixture files or directories are removed.
final class DocxCompatibilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOrbit-docx-compatibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private enum FixturePage {
        case text([String])
        case scanned
        case blank
    }

    private enum InjectedFailure: Error, Equatable {
        case unexpectedRecognition
        case recognitionFailed
    }

    private func normalized(_ string: String) -> String {
        string.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private func draw(_ lines: [String], in context: CGContext) {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 20, nil)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 36, y: 700 - index * 38)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }

    private func makePDF(_ name: String, pages: [FixturePage]) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(box)
            switch page {
            case .text(let lines):
                draw(lines, in: context)
            case .scanned:
                let bitmap = try XCTUnwrap(CGContext(data: nil, width: 595, height: 842,
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(box)
                draw(["Scanned sample 扫描测试"], in: bitmap)
                context.draw(try XCTUnwrap(bitmap.makeImage()), in: box)
            case .blank:
                break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func readWithTextKit(_ url: URL) throws -> NSAttributedString {
        try NSAttributedString(url: url,
            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
            documentAttributes: nil)
    }

    func testDefaultPDFConversionOpensInTextKitWithEveryPagesChineseAndEnglish() async throws {
        let pageText = [
            ["第一页：中文转换测试", "Page One: Research & Development"],
            ["第二页：工作经历与技能", "Page Two: Swift and PDF <sample>"],
            ["第三页：教育背景", "Page Three: Final content 2026"]
        ]
        let input = try makePDF("multilingual", pages: pageText.map(FixturePage.text))
        let original = try Data(contentsOf: input)
        let pdf = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertEqual(pdf.pageCount, pageText.count)
        // Check the fixture independently: these really are readable PDF text layers.
        for (index, lines) in pageText.enumerated() {
            XCTAssertEqual(normalized(pdf.page(at: index)?.string ?? ""), normalized(lines.joined()))
        }
        let options = ConversionOptions()
        XCTAssertEqual(options.pdfDocxMode, .editableText)
        // Text-layer PDFs must not depend on OCR being available.
        _ = try PDFConverter.makeDocx(input, options: options) { _, _ in
            throw InjectedFailure.unexpectedRecognition
        }
        let outputs = try await PDFConverter.convert(input, to: .docx, options: options)
        XCTAssertEqual(outputs.count, 1)
        let output = try XCTUnwrap(outputs.first)
        let imported = try readWithTextKit(output)
        XCTAssertEqual(normalized(imported.string), normalized(pageText.flatMap { $0 }.joined()))
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testAppearanceIsExplicitAndContainsImagesInsteadOfEditableText() throws {
        let input = try makePDF("appearance", pages: [.text(["Visible page 页面内容"]), .scanned])
        var options = ConversionOptions()
        XCTAssertEqual(options.pdfDocxMode, .editableText)
        options.pdfDocxMode = .preserveAppearance
        let document = try PDFConverter.makeDocx(input, options: options) { _, _ in
            throw InjectedFailure.unexpectedRecognition
        }
        let images = document.blocks.compactMap { block -> DocxImage? in
            if case .image(let image) = block { return image }
            return nil
        }
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images.allSatisfy { !$0.data.isEmpty && $0.width > 0 && $0.height > 0 })
        let output = directory.appendingPathComponent("appearance.docx")
        try DocxWriter.write(document, to: output)
        let imported = try readWithTextKit(output)
        // This is the actual macOS TextKit regression: page images provide no readable text.
        // The appearance option must remain opt-in; a successful image write is not a text test.
        XCTAssertTrue(normalized(imported.string).isEmpty)
    }

    func testScannedPDFUsesRecognizedTextThatTextKitCanRead() throws {
        let input = try makePDF("scan", pages: [.scanned])
        let pdf = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertTrue(normalized(pdf.page(at: 0)?.string ?? "").isEmpty)
        var recognitionCalls = 0
        let recognized = ["扫描识别结果", "Recognized English text"]
        let document = try PDFConverter.makeDocx(input, options: ConversionOptions()) { image, languages in
            recognitionCalls += 1
            XCTAssertGreaterThan(image.width, 0)
            XCTAssertFalse(languages.isEmpty)
            return recognized
        }
        XCTAssertEqual(recognitionCalls, 1)
        let output = directory.appendingPathComponent("recognized.docx")
        try DocxWriter.write(document, to: output)
        XCTAssertEqual(normalized(try readWithTextKit(output).string), normalized(recognized.joined()))
    }

    func testEmptyAndWhitespaceOnlyRecognitionFailInsteadOfMakingEmptyWord() throws {
        let input = try makePDF("unreadable-scan", pages: [.scanned])
        for recognized in [[], [""], [" ", "\n\t", "\u{3000}"]] as [[String]] {
            XCTAssertThrowsError(try PDFConverter.makeDocx(input, options: ConversionOptions()) { _, _ in
                recognized
            })
        }
    }

    func testRecognitionErrorsArePropagated() throws {
        let input = try makePDF("ocr-error", pages: [.scanned])
        XCTAssertThrowsError(try PDFConverter.makeDocx(input, options: ConversionOptions()) { _, _ in
            throw InjectedFailure.recognitionFailed
        }) { error in
            XCTAssertEqual(error as? InjectedFailure, .recognitionFailed)
        }
    }

    func testUnreadableLaterPageDoesNotPublishPartialWordOrOverwriteExistingResult() throws {
        let input = try makePDF("partial", pages: [.text(["First page must not escape alone"]), .scanned])
        let originalPDF = try Data(contentsOf: input)
        let destination = directory.appendingPathComponent("partial.docx")
        let originalResult = Data("existing result must remain unchanged".utf8)
        try originalResult.write(to: destination)
        var recognitionCalls = 0
        XCTAssertThrowsError(try OutputNaming.write(to: destination) { pending in
            let document = try PDFConverter.makeDocx(input, options: ConversionOptions()) { _, _ in
                recognitionCalls += 1
                return []
            }
            try DocxWriter.write(document, to: pending)
        }) { error in
            XCTAssertTrue(ConversionEngine.message(for: error).contains("2"), "Error should identify the unreadable page")
        }
        XCTAssertEqual(recognitionCalls, 1)
        XCTAssertEqual(try Data(contentsOf: destination), originalResult)
        XCTAssertEqual(try Data(contentsOf: input), originalPDF)
        let published = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "docx" }
        XCTAssertEqual(published.map { $0.resolvingSymlinksInPath() }, [destination.resolvingSymlinksInPath()])
    }

    func testRealBlankPDFConversionDoesNotPublishSuccessfulEmptyWord() async throws {
        let input = try makePDF("blank", pages: [.blank])
        let destination = OutputNaming.convertedURL(for: input, ext: "docx")
        do {
            let outputs = try await PDFConverter.convert(input, to: .docx, options: ConversionOptions())
            XCTFail("Blank PDF must fail instead of reporting successful outputs: \(outputs)")
        } catch {
            // The deterministic empty-OCR tests above prove the content guard. This integration
            // check also permits an explicit Vision/environment error, but never a blank success.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }

    func testTextExtractionRejectsEmptyRecognitionOnAnyPageWithoutPublishingPartialText() throws {
        let input = try makePDF("partial-text", pages: [.text(["First page text"]), .scanned])
        let destination = directory.appendingPathComponent("partial-text.txt")
        let original = try Data(contentsOf: input)
        for recognized in [[], [" \n\t " ]] {
            XCTAssertThrowsError(try OutputNaming.write(to: destination) { pending in
                let text = try PDFConverter.extractText(input, options: ConversionOptions()) { _, _ in recognized }
                try text.write(to: pending, atomically: false, encoding: .utf8)
            }) { error in
                XCTAssertTrue(ConversionEngine.message(for: error).contains("第 2 页"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
}

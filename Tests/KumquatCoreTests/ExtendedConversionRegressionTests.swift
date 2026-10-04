import Foundation
import AppKit
import PDFKit
import XCTest
@testable import KumquatCore

final class ExtendedConversionRegressionTests: XCTestCase {
    func testPDFFormValuesSurviveTextWordAndRasterOutputs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrbit-pdf-form-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("form.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        let doc = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(doc.page(at: 0))
        let field = PDFAnnotation(bounds: CGRect(x: 30, y: 100, width: 340, height: 50), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text; field.fieldName = "Name"; field.widgetStringValue = "FORM VALUE 12345"
        field.font = NSFont.systemFont(ofSize: 22); field.backgroundColor = .yellow
        page.addAnnotation(field)
        XCTAssertTrue(doc.write(to: source))
        XCTAssertTrue(try PDFConverter.extractText(source, options: ConversionOptions()) { _, _ in [] }.contains("FORM VALUE 12345"))
        let word = try PDFConverter.makeDocx(source, options: ConversionOptions()) { _, _ in [] }
        let text = try NSAttributedString(data: DocxWriter.data(for: word), options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        XCTAssertTrue(text.contains("FORM VALUE 12345"))
        let reopened = try XCTUnwrap(PDFDocument(url: source)?.page(at: 0))
        let image = try XCTUnwrap(PDFRenderer.render(reopened, dpi: 72))
        let pixels = try XCTUnwrap(RGBABuffer(image: image)).pixels
        var yellow = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] > 180 && pixels[i + 1] > 180 && pixels[i + 2] < 100 { yellow += 1 }
        }
        XCTAssertGreaterThan(yellow, 5_000, "Filled widget appearance was omitted from the rendered page")
        field.widgetStringValue = "Off"
        XCTAssertTrue(doc.write(to: source))
        var recognized = false
        let scanText = try PDFConverter.extractText(source, options: ConversionOptions()) { _, _ in
            recognized = true
            return ["SCANNED BODY 98765"]
        }
        XCTAssertTrue(recognized, "A filled widget must not suppress OCR of the scanned page behind it")
        XCTAssertTrue(scanText.contains("SCANNED BODY 98765"))
        XCTAssertTrue(scanText.contains("Name: Off"), "Off is a valid text field value")
    }

    func testGzipAliasTranscodesPayloadInsteadOfWrappingCompressedBytes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrbit-gzip-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appendingPathComponent("payload.txt")
        let expected = Data("GZIP alias 中文 payload\n".utf8)
        try expected.write(to: source)
        let compressed = try await ArchiveConverter.convert(source, to: .gz)
        let alias = dir.appendingPathComponent("archive.gzip")
        try FileManager.default.copyItem(at: XCTUnwrap(compressed.first), to: alias)
        let original = try Data(contentsOf: alias)
        for format in [OutputFormat.zip, .tar, .gz] {
            let converted = try await ArchiveConverter.convert(alias, to: format)
            let extracted = try await ArchiveConverter.extract(XCTUnwrap(converted.first))
            let folder = try XCTUnwrap(extracted.first)
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), expected)
        }
        let direct = try await ArchiveConverter.extract(alias)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(direct.first).appendingPathComponent("archive")), expected)
        XCTAssertEqual(try Data(contentsOf: alias), original)
    }
}

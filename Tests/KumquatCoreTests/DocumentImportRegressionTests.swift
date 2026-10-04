import AppKit
import PDFKit
import XCTest
@testable import KumquatCore

final class DocumentImportRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrbit-DocImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func styledDocument(_ directory: URL, header: Bool = false) throws -> URL {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", text: """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>
        """)
        zip.add("_rels/.rels", text: """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """)
        zip.add("word/_rels/document.xml.rels", text: """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/></Relationships>
        """)
        zip.add("word/document.xml", text: """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:pPr><w:pStyle w:val="CustomTitle"/></w:pPr><w:r><w:t>STYLE TITLE</w:t></w:r></w:p><w:p><w:r><w:t>Body paragraph with enough text to establish the regular size.</w:t></w:r></w:p><w:p><w:pPr><w:pStyle w:val="ListBullet"/></w:pPr><w:r><w:t>Bullet item</w:t></w:r></w:p><w:p><w:pPr><w:pStyle w:val="ListNumber"/></w:pPr><w:r><w:t>First numbered item</w:t></w:r></w:p><w:p><w:pPr><w:pStyle w:val="ListNumber"/></w:pPr><w:r><w:t>Second numbered item</w:t></w:r></w:p><w:sectPr><w:pgSz w:w="11906" w:h="16838"/></w:sectPr></w:body></w:document>
        """)
        zip.add("word/styles.xml", text: """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:styleId="Normal" w:default="1"><w:rPr><w:sz w:val="24"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Title"><w:basedOn w:val="Normal"/><w:rPr><w:sz w:val="48"/><w:b/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="CustomTitle"><w:basedOn w:val="Title"/></w:style><w:style w:type="paragraph" w:styleId="ListBullet"><w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr></w:style><w:style w:type="paragraph" w:styleId="ListNumber"><w:pPr><w:numPr><w:numId w:val="2"/></w:numPr></w:pPr></w:style></w:styles>
        """)
        zip.add("word/numbering.xml", text: """
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="2"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="2"/></w:num></w:numbering>
        """)
        if header { zip.add("word/header1.xml", text: "<w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>Important header text</w:t></w:r></w:p></w:hdr>") }
        let output = directory.appendingPathComponent("styled.docx")
        try zip.finish().write(to: output)
        return output
    }

    private func rewrittenDocument(_ input: URL, name: String,
                                   edits: [String: (String) -> String], additions: [String: Data] = [:]) throws -> URL {
        let reader = try ArchiveConverter.Reader(input: input, library: ArchiveLibrary(), limits: .init())
        var zip = ZipWriter()
        while let entry = try reader.next() {
            var data = Data()
            while let chunk = try reader.chunk() { data.append(chunk) }
            if let edit = edits[entry.name] {
                data = Data(edit(try XCTUnwrap(String(data: data, encoding: .utf8))).utf8)
            }
            if !entry.directory { zip.add(entry.name, data: data) }
        }
        for (path, data) in additions { zip.add(path, data: data) }
        let output = input.deletingLastPathComponent().appendingPathComponent(name + ".docx")
        try zip.finish().write(to: output)
        return output
    }

    @MainActor
    func testUnsupportedWordNumberingCannotSilentlyBecomeDecimal() async throws {
        let dir = try directory()
        let simple = try styledDocument(dir)
        let variants: [(String, (String) -> String)] = [
            ("roman", { $0.replacingOccurrences(of: "w:val=\"decimal\"", with: "w:val=\"lowerRoman\"") }),
            ("custom-marker", { $0.replacingOccurrences(of: "w:val=\"%1.\"", with: "w:val=\"Chapter %1)\"") }),
            ("multilevel", { $0.replacingOccurrences(of: "</w:abstractNum>", with: "<w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.%2.\"/></w:lvl></w:abstractNum>") }),
            ("start-override", { $0.replacingOccurrences(of: "<w:abstractNumId w:val=\"2\"/>", with: "<w:abstractNumId w:val=\"2\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"7\"/></w:lvlOverride>") }),
            ("level-override", { $0.replacingOccurrences(of: "<w:abstractNumId w:val=\"2\"/>", with: "<w:abstractNumId w:val=\"2\"/><w:lvlOverride w:ilvl=\"0\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"3\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/></w:lvl></w:lvlOverride>") }),
        ]
        for (name, edit) in variants {
            let input = try rewrittenDocument(simple, name: name, edits: ["word/numbering.xml": edit])
            let original = try Data(contentsOf: input)
            for format in [OutputFormat.pdf, .txt, .md] {
                do {
                    _ = try await DocumentConverter.convert(input, to: format)
                    XCTFail("Unsupported numbering must fail: \(name)")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("复杂列表编号"), error.localizedDescription)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: input.deletingPathExtension().appendingPathExtension(format.fileExtension).path))
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    @MainActor
    func testImageOnlyWordHeaderCannotSilentlyDisappear() async throws {
        let dir = try directory()
        let simple = try styledDocument(dir)
        let header = """
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:v="urn:schemas-microsoft-com:vml"><w:p><w:r><w:pict><v:shape style="width:12pt;height:12pt"><v:imagedata r:id="rIdImage"/></v:shape></w:pict></w:r></w:p></w:hdr>
        """
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGMUSbnDgA0wYRUdtBIADUcBZC9upwQAAAAASUVORK5CYII="))
        let input = try rewrittenDocument(simple, name: "image-header", edits: [
            "[Content_Types].xml": { $0.replacingOccurrences(of: "</Types>", with: "<Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/></Types>") },
            "word/document.xml": { $0.replacingOccurrences(of: "<w:sectPr>", with: "<w:sectPr><w:headerReference xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" w:type=\"default\" r:id=\"rIdHeader\"/>") },
            "word/_rels/document.xml.rels": { $0.replacingOccurrences(of: "</Relationships>", with: "<Relationship Id=\"rIdHeader\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/></Relationships>") },
        ], additions: ["word/header1.xml": Data(header.utf8), "word/media/header.png": image,
                       "word/_rels/header1.xml.rels": Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdImage\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/header.png\"/></Relationships>".utf8)])
        let original = try Data(contentsOf: input)
        for format in [OutputFormat.pdf, .txt, .md] {
            do {
                _ = try await DocumentConverter.convert(input, to: format)
                XCTFail("A header containing only an image must report its limitation")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("页眉"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("image-header." + format.fileExtension).path))
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    @MainActor
    func testWordStyleInheritanceAndListMarkersSurviveActualMarkdownAndPDF() async throws {
        let dir = try directory()
        let input = try styledDocument(dir)
        let original = try Data(contentsOf: input)
        let markdown = try await DocumentConverter.convert(input, to: .md)
        let text = try String(contentsOf: XCTUnwrap(markdown.first), encoding: .utf8)
        XCTAssertTrue(text.contains("# STYLE TITLE"), text)
        XCTAssertTrue(text.contains("- Bullet item"), text)
        XCTAssertTrue(text.contains("1. First numbered item"), text)
        XCTAssertTrue(text.contains("2. Second numbered item"), text)
        let pdfs = try await DocumentConverter.convert(input, to: .pdf)
        let pdf = try XCTUnwrap(PDFDocument(url: XCTUnwrap(pdfs.first)))
        let rendered = try XCTUnwrap(pdf.string)
        XCTAssertTrue(rendered.contains("STYLE TITLE"))
        XCTAssertTrue(rendered.contains("•"))
        XCTAssertTrue(rendered.contains("Second numbered item"))
        let attributed = try DocumentConverter.read(input)
        let font = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 24, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    @MainActor
    func testWordHeaderContentCannotSilentlyDisappear() async throws {
        let dir = try directory()
        let input = try styledDocument(dir, header: true)
        for format in [OutputFormat.pdf, .txt, .md] {
            do {
                _ = try await DocumentConverter.convert(input, to: format)
                XCTFail("A conversion that loses header text must report its limitation")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("页眉"), error.localizedDescription)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("styled." + format.fileExtension).path))
        }
    }

    @MainActor
    func testHTMLAttachmentsAreSelfContainedAndRichUnsupportedExportsReject() throws {
        let dir = try directory()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = NSTextAttachment()
        attachment.fileWrapper = FileWrapper(regularFileWithContents: data)
        attachment.fileWrapper?.preferredFilename = "test.png"
        let document = NSMutableAttributedString(string: "BEFORE\n")
        document.append(NSAttributedString(attachment: attachment))
        document.append(NSAttributedString(string: "\nAFTER"))
        let html = dir.appendingPathComponent("self-contained.html")
        try DocumentConverter.write(document, as: .html, to: html, title: "Attachment")
        let result = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(result.contains("data:image/png;base64,"))
        XCTAssertFalse(result.contains("file:///"))
        XCTAssertTrue(result.contains("BEFORE") && result.contains("AFTER"))
        for format in [OutputFormat.rtf, .odt, .docx] {
            XCTAssertThrowsError(try DocumentConverter.write(document, as: format,
                to: dir.appendingPathComponent("unsupported." + format.fileExtension), title: "Attachment"))
        }
        let plain = dir.appendingPathComponent("body.txt")
        try DocumentConverter.write(document, as: .txt, to: plain, title: "Attachment")
        XCTAssertEqual(try String(contentsOf: plain, encoding: .utf8), "BEFORE\n[图片]\nAFTER")
    }
}

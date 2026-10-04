import AppKit
import PDFKit
import XCTest
@testable import KumquatCore

/// Test artifacts are deliberately retained under the system temporary directory for inspection.
final class DocumentRegressionTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrbit-document-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func file(_ name: String, _ text: String) throws -> URL {
        let result = directory.appendingPathComponent(name)
        try text.write(to: result, atomically: false, encoding: .utf8)
        return result
    }

    func testSubtitleRoundTripKeepsMillisecondsMultilineAndUnicode() throws {
        let original = "1\r\n00:00:01,250 --> 00:00:04,001\r\n第一行\r\nSecond line\r\n\r\n2\r\n01:10:00,000 --> 01:10:01,999\r\n下一句\r\n"
        let srt = try file("captions.srt", original)
        let vtt = try XCTUnwrap(SubtitleConverter.convert(srt, to: .vtt).first)
        XCTAssertTrue(try String(contentsOf: vtt, encoding: .utf8).contains("00:00:01.250 --> 00:00:04.001\n第一行\nSecond line"))
        let back = try XCTUnwrap(SubtitleConverter.convert(vtt, to: .srt).first)
        XCTAssertEqual(try SubtitleConverter.parse(original, webVTT: false),
                       try SubtitleConverter.parse(String(contentsOf: back, encoding: .utf8), webVTT: false))
        let text = try XCTUnwrap(SubtitleConverter.convert(srt, to: .txt).first)
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "第一行\nSecond line\n\n下一句\n")
    }

    func testSubtitleRejectsInventedTimingAndMalformedOrUnsupportedCues() throws {
        let txt = try file("untimed.txt", "Hello\nWorld")
        XCTAssertThrowsError(try SubtitleConverter.convert(txt, to: .srt))
        XCTAssertThrowsError(try SubtitleConverter.parse("1\n00:00:02,000 --> 00:00:01,000\nWrong", webVTT: false))
        XCTAssertThrowsError(try SubtitleConverter.parse("1\n00:61:02,000 --> 00:62:01,000\nWrong", webVTT: false))
        XCTAssertThrowsError(try SubtitleConverter.parse("WEBVTT\n\nSTYLE\n::cue { color: red; }\n\n00:01.000 --> 00:02.000\nHello", webVTT: true))
        XCTAssertThrowsError(try SubtitleConverter.parse("WEBVTT\n\n00:01.000 --> 00:02.000 position:50%\nHello", webVTT: true))
        let short = try SubtitleConverter.parse("WEBVTT\n\nNOTE ignored\ncomment\n\ncue-id\n01:01.002 --> 01:02.003\nHello", webVTT: true)
        XCTAssertEqual(short.first?.startMilliseconds, 61_002)
        XCTAssertEqual(short.first?.endMilliseconds, 62_003)
    }

    func testPageOrderSupportsRangesReverseRepeatAndRejectsBadInput() throws {
        XCTAssertEqual(try PDFTools.pageOrder("3,1-2,5-4,3", pageCount: 5), [3, 1, 2, 5, 4, 3])
        XCTAssertEqual(try PDFTools.pageOrder(" 2 ， 1 ", pageCount: 2), [2, 1])
        for invalid in ["", "0", "6", "1,", "-1", "1-0", "1-3-4", "x", "1,,2"] {
            XCTAssertThrowsError(try PDFTools.pageOrder(invalid, pageCount: 5), invalid)
        }
    }

    func makePDF() throws -> URL {
        let url = directory.appendingPathComponent("fixture.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for width in [200, 300, 400] {
            var pageBox = CGRect(x: 0, y: 0, width: width, height: 100)
            context.beginPage(mediaBox: &pageBox)
            context.setFillColor(CGColor(srgbRed: Double(width) / 400, green: 0.2, blue: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: 100))
            context.endPage()
        }
        context.closePDF()
        return url
    }

    func testPDFReorderReallyChangesPageOrderAndPreservesOriginal() throws {
        let input = try makePDF()
        let output = try PDFTools.reorder(input, pages: "3,1-2,2")
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertEqual((0..<4).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).width }, [400, 200, 300, 300])
        XCTAssertEqual(PDFDocument(url: input)?.pageCount, 3)
        let page = try XCTUnwrap(PDFRenderer.document(at: input).page(at: 1))
        XCTAssertTrue(PDFRenderer.render(page, dpi: .nan) == nil)
        XCTAssertTrue(PDFRenderer.render(page, dpi: .infinity) == nil)
        XCTAssertTrue(PDFRenderer.render(page, dpi: -1) == nil)
    }

    func testPDFExplicitAppearanceDocxCarriesEveryPageGraphic() throws {
        let input = try makePDF()
        var options = ConversionOptions(); options.pdfDocxMode = .preserveAppearance
        let docx = try PDFConverter.makeDocx(input, options: options)
        let images = docx.blocks.compactMap { block -> DocxImage? in if case .image(let image) = block { return image }; return nil }
        XCTAssertEqual(images.count, 3)
        XCTAssertTrue(images.allSatisfy { $0.fileExtension == "png" && !$0.data.isEmpty })
        XCTAssertEqual(images.map { ($0.width / $0.height).rounded() }, [2, 3, 4])
        let pages = try PDFTools.split(input)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pages.path).count, 3)
    }

    func testIncompleteFolderIsNotPublishedAndPartialOutputIsRetained() throws {
        let destination = directory.appendingPathComponent("Completed Pages")
        var retained: URL?
        XCTAssertThrowsError(try DocumentStaging.writeDirectory(to: destination) { pending in
            retained = pending
            try Data([1, 2, 3]).write(to: pending.appendingPathComponent("first.bin"))
            throw KumquatError.processFailed("injected failure")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let pending = try XCTUnwrap(retained)
        XCTAssertEqual(try Data(contentsOf: pending.appendingPathComponent("first.bin")), Data([1, 2, 3]))
    }

    func testArchiveZIPTarAndGzipRoundTripAndTranscode() async throws {
        let input = try file("sample.txt", "中文 and bytes\n" + String(repeating: "Archive\n", count: 128))
        let expected = try Data(contentsOf: input)
        for format in [OutputFormat.zip, .tar, .gz] {
            let results1 = try await ArchiveConverter.convert(input, to: format)
            let archive = try XCTUnwrap(results1.first)
            let results2 = try await ArchiveConverter.extract(archive)
            let unpacked = try XCTUnwrap(results2.first)
            XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent("sample.txt")), expected, format.title)
        }
        let results3 = try await ArchiveConverter.convert(input, to: .zip)
        let zip = try XCTUnwrap(results3.first)
        let results4 = try await ArchiveConverter.convert(zip, to: .tar)
        let tar = try XCTUnwrap(results4.first)
        let results5 = try await ArchiveConverter.extract(tar)
        let folder = try XCTUnwrap(results5.first)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("sample.txt")), expected)
        let results6 = try await ArchiveConverter.convert(input, to: .gz)
        let gz = try XCTUnwrap(results6.first)
        let results7 = try await ArchiveConverter.convert(gz, to: .tar)
        let fromGzip = try XCTUnwrap(results7.first)
        let results8 = try await ArchiveConverter.extract(fromGzip)
        let rawFolder = try XCTUnwrap(results8.first)
        // A unique gzip filename contains the numeric suffix; its payload must still survive.
        let files = try FileManager.default.contentsOfDirectory(at: rawFolder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: files[0]), expected)
    }

    func testArchiveDirectoryGzipActuallyCreatesTarGzip() async throws {
        let source = directory.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("nested.bin"))
        let results9 = try await ArchiveConverter.convert(source, to: .gz)
        let archive = try XCTUnwrap(results9.first)
        XCTAssertTrue(archive.lastPathComponent.hasSuffix(".tar.gz"))
        let results10 = try await ArchiveConverter.extract(archive)
        let result = try XCTUnwrap(results10.first)
        XCTAssertEqual(try Data(contentsOf: result.appendingPathComponent("folder/nested.bin")), Data([1, 2, 3]))
    }

    func testArchiveUnicodeNamesAndRawGzipExpandedSizeLimit() async throws {
        let input = try file("数据 一.txt", String(repeating: "x", count: 32_768))
        for format in [OutputFormat.zip, .tar, .gz] {
            let results = try await ArchiveConverter.convert(input, to: format)
            let archive = try XCTUnwrap(results.first)
            let results2 = try await ArchiveConverter.extract(archive)
            let folder = try XCTUnwrap(results2.first)
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(input.lastPathComponent)), try Data(contentsOf: input))
            if format == .gz {
                var limits = ArchiveConverter.Limits(); limits.maximumFileBytes = 1024
                XCTAssertThrowsError(try ArchiveConverter.extract(archive, limits: limits))
            }
        }
    }

    func testArchiveBlocksTraversalAbsolutePathsAndDuplicateEntries() throws {
        for name in ["../escaped.txt", "/absolute.txt", "dir/../../escaped.txt", "C:/windows.txt", "..\\escaped.txt"] {
            var zip = ZipWriter()
            zip.add(name, text: "bad")
            let input = directory.appendingPathComponent("unsafe-\(UUID().uuidString).zip")
            try zip.finish().write(to: input)
            XCTAssertThrowsError(try ArchiveConverter.extract(input, limits: .init()), name)
        }
        var zip = ZipWriter()
        zip.add("duplicate.txt", text: "first")
        zip.add("duplicate.txt", text: "second")
        let input = directory.appendingPathComponent("duplicate.zip")
        try zip.finish().write(to: input)
        XCTAssertThrowsError(try ArchiveConverter.extract(input, limits: .init()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped.txt").path))
    }

    func testArchiveEnforcesActualExpansionAndEntryLimits() throws {
        var zip = ZipWriter()
        zip.add("big.txt", text: String(repeating: "a", count: 32_768))
        let input = directory.appendingPathComponent("bomb.zip")
        try zip.finish().write(to: input)
        var limits = ArchiveConverter.Limits()
        limits.maximumFileBytes = 1024
        XCTAssertThrowsError(try ArchiveConverter.extract(input, limits: limits))
        limits.maximumFileBytes = 100_000
        limits.maximumExpansionRatio = 2
        limits.expansionAllowanceBytes = 0
        XCTAssertThrowsError(try ArchiveConverter.extract(input, limits: limits))
        var entries = ZipWriter()
        entries.add("a", text: "1"); entries.add("b", text: "2")
        let many = directory.appendingPathComponent("entries.zip")
        try entries.finish().write(to: many)
        limits = .init(); limits.maximumEntries = 1
        XCTAssertThrowsError(try ArchiveConverter.extract(many, limits: limits))
    }

    func testArchiveRejectsLinksSpecialFilesAndBadGzip() throws {
        for type: UInt8 in [49, 50, 51, 54] { // tar hard link, symlink, character device, FIFO
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ offset: Int, _ value: String) { for (i, byte) in value.utf8.enumerated() { header[offset + i] = byte } }
            field(0, "evil"); field(100, "0000644\0"); field(108, "0000000\0"); field(116, "0000000\0")
            field(124, "00000000000\0"); field(136, "00000000000\0")
            for i in 148..<156 { header[i] = 32 }
            header[156] = type; field(157, "../escape"); field(257, "ustar\0"); field(263, "00")
            field(148, String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ")
            var archive = Data(header); archive.append(Data(repeating: 0, count: 1024))
            let input = directory.appendingPathComponent("link-\(type).tar")
            try archive.write(to: input)
            XCTAssertThrowsError(try ArchiveConverter.extract(input, limits: .init()))
        }
        let gzip = try file("broken.gz", "not gzip")
        XCTAssertThrowsError(try ArchiveConverter.extract(gzip, limits: .init()))
    }
}

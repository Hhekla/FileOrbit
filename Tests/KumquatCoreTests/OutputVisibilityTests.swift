import AppKit
import Darwin
import ImageIO
import XCTest
@testable import KumquatCore

/// Retained synthetic fixtures exercise filesystem visibility, not merely file existence.
/// No user files are read and no test files or directories are deleted.
final class OutputVisibilityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileOrbit-output-visibility-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func flags(_ url: URL) throws -> UInt32 {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return info.st_flags
    }

    private func setFlags(_ value: UInt32, at url: URL) throws {
        guard url.path.withCString({ chflags($0, value) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func finderInfo(_ url: URL) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = url.path.withCString { path in
            bytes.withUnsafeMutableBytes { buffer in
                getxattr(path, "com.apple.FinderInfo", buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard count == bytes.count else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Data(bytes)
    }

    private func setFinderInfo(_ data: Data, at url: URL) throws {
        let result = url.path.withCString { path in
            data.withUnsafeBytes { buffer in
                setxattr(path, "com.apple.FinderInfo", buffer.baseAddress, buffer.count, 0, 0)
            }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func assertVisible(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        // A fresh URL avoids a resource-value cache from before the atomic move.
        let fresh = URL(fileURLWithPath: url.path)
        XCTAssertEqual(try flags(fresh) & UInt32(UF_HIDDEN), 0, url.lastPathComponent, file: file, line: line)
        XCTAssertFalse(try fresh.resourceValues(forKeys: [.isHiddenKey]).isHidden ?? true,
                       url.lastPathComponent, file: file, line: line)
        let visibleSiblings = try FileManager.default.contentsOfDirectory(
            at: fresh.deletingLastPathComponent(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        XCTAssertTrue(visibleSiblings.contains { $0.lastPathComponent == fresh.lastPathComponent },
                      "Published result must appear in a normal Finder-style listing", file: file, line: line)
    }

    private func makePDF(_ name: String, pages: Int) throws -> URL {
        let url = directory.appendingPathComponent(name).appendingPathExtension("pdf")
        var box = CGRect(x: 0, y: 0, width: 120, height: 80)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(srgbRed: Double(index + 1) / Double(pages + 1),
                                         green: 0.25, blue: 0.6, alpha: 1))
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func assertPNG(_ url: URL) throws {
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 80)
    }

    func testSinglePagePDFPublishesVisibleDecodablePNGWithoutChangingSourceMetadata() async throws {
        let input = try makePDF("Single page", pages: 1)
        try setFlags(UInt32(UF_HIDDEN | UF_NODUMP), at: input)
        let originalBytes = try Data(contentsOf: input)
        let originalFlags = try flags(input)
        var options = ConversionOptions(); options.pdfDPI = 72
        let outputs = try await PDFConverter.convert(input, to: .png, options: options)
        XCTAssertEqual(outputs.count, 1)
        let output = try XCTUnwrap(outputs.first)
        XCTAssertEqual(output.lastPathComponent, "Single page.png")
        try assertVisible(output)
        try assertPNG(output)
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        XCTAssertEqual(try flags(input), originalFlags)
    }

    func testMultiplePagePDFPublishesVisibleFolderAndEveryPNGWithoutChangingSource() async throws {
        let input = try makePDF("Roadbook", pages: 12)
        try setFlags(UInt32(UF_NODUMP), at: input)
        let originalBytes = try Data(contentsOf: input)
        let originalFlags = try flags(input)
        var options = ConversionOptions(); options.pdfDPI = 72
        let outputs = try await PDFConverter.convert(input, to: .png, options: options)
        XCTAssertEqual(outputs.count, 1)
        let folder = try XCTUnwrap(outputs.first)
        XCTAssertEqual(folder.lastPathComponent, "Roadbook Pages")
        try assertVisible(folder)
        let pages = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(pages.map(\.lastPathComponent), (1...12).map { String(format: "Page %02d.png", $0) })
        for page in pages {
            try assertVisible(page)
            try assertPNG(page)
        }
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        XCTAssertEqual(try flags(input), originalFlags)
    }

    func testSynchronousPublicationClearsInheritedHiddenFlagAndKeepsOtherFlagsAndBytes() throws {
        let expected = Data("Completed result 正文".utf8)
        let output = try OutputNaming.write(to: directory.appendingPathComponent("Visible.txt")) { pending in
            try expected.write(to: pending)
            try self.setFlags(UInt32(UF_HIDDEN | UF_NODUMP), at: pending)
            XCTAssertNotEqual(try self.flags(pending) & UInt32(UF_HIDDEN), 0)
        }
        try assertVisible(output)
        XCTAssertNotEqual(try flags(output) & UInt32(UF_NODUMP), 0)
        XCTAssertEqual(try Data(contentsOf: output), expected)
    }

    func testAsynchronousPublicationClearsInheritedHiddenFlagAndKeepsOtherFlagsAndBytes() async throws {
        let expected = Data("Async result 异步正文".utf8)
        let output = try await OutputNaming.write(to: directory.appendingPathComponent("Async.txt")) { pending in
            await Task.yield()
            try expected.write(to: pending)
            try self.setFlags(UInt32(UF_HIDDEN | UF_NODUMP), at: pending)
            XCTAssertNotEqual(try self.flags(pending) & UInt32(UF_HIDDEN), 0)
        }
        try assertVisible(output)
        XCTAssertNotEqual(try flags(output) & UInt32(UF_NODUMP), 0)
        XCTAssertEqual(try Data(contentsOf: output), expected)
    }

    func testDirectoryPublicationClearsInheritedHiddenFlagsOnFolderAndNestedFilesOnly() throws {
        let source = directory.appendingPathComponent("Original.txt")
        let expected = Data("Original source stays unchanged".utf8)
        try expected.write(to: source)
        try setFlags(UInt32(UF_HIDDEN | UF_NODUMP), at: source)
        let originalFlags = try flags(source)
        let output = try DocumentStaging.writeDirectory(to: directory.appendingPathComponent("Visible Pages")) { pending in
            let nested = pending.appendingPathComponent("Nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let child = nested.appendingPathComponent("Page 01.txt")
            try expected.write(to: child)
            let intentionalHidden = pending.appendingPathComponent(".metadata")
            try expected.write(to: intentionalHidden)
            try self.setFlags(UInt32(UF_HIDDEN | UF_NODUMP), at: intentionalHidden)
            try FileManager.default.createSymbolicLink(at: pending.appendingPathComponent("Source link"),
                                                      withDestinationURL: source)
            for url in [pending, nested, child] {
                try self.setFlags(UInt32(UF_HIDDEN | UF_NODUMP), at: url)
                XCTAssertNotEqual(try self.flags(url) & UInt32(UF_HIDDEN), 0)
            }
        }
        let nested = output.appendingPathComponent("Nested")
        let child = nested.appendingPathComponent("Page 01.txt")
        for url in [output, nested, child] {
            try assertVisible(url)
            XCTAssertNotEqual(try flags(url) & UInt32(UF_NODUMP), 0)
        }
        XCTAssertEqual(try Data(contentsOf: child), expected)
        XCTAssertEqual(try Data(contentsOf: source), expected)
        XCTAssertEqual(try flags(source), originalFlags)
        let intentionalHidden = output.appendingPathComponent(".metadata")
        XCTAssertNotEqual(try flags(intentionalHidden) & UInt32(UF_HIDDEN), 0)
        XCTAssertEqual(try Data(contentsOf: intentionalHidden), expected)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: output.appendingPathComponent("Source link").path), source.path)
    }

    func testPublicationClearsFinderInvisibleBitAndPreservesUnrelatedFinderMetadata() throws {
        var original = Data(repeating: 0, count: 32)
        original.replaceSubrange(0..<8, with: Data("TEXTttxt".utf8))
        original[8] = 0x40 // kIsInvisible, the high byte of the big-endian Finder flags.
        original[9] = 0x0e // Label bits must survive.
        let output = try OutputNaming.write(to: directory.appendingPathComponent("Finder-visible.txt")) { pending in
            try Data("Finder metadata fixture".utf8).write(to: pending)
            try self.setFinderInfo(original, at: pending)
            XCTAssertEqual(try self.finderInfo(pending), original)
        }
        var expected = original
        expected[8] &= ~0x40
        XCTAssertEqual(try finderInfo(output), expected)
        try assertVisible(output)
    }
}

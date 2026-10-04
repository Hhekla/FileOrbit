import AppKit
import XCTest
@testable import KumquatCore

final class EngineRegressionTests: XCTestCase {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrbit-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    var engine: ConversionEngine { ConversionEngine(capabilities: Capabilities.detect(useExternalTools: false), options: ConversionOptions()) }
    func testEmptyAndDirectoryInputsAreReported() async throws {
        let empty = await engine.run(.tool(.merge), on: [])
        XCTAssertEqual(empty.succeededInputs, 0)
        XCTAssertEqual(empty.failures.count, 1)
        let dir = try folder()
        let report = await engine.run(.convert(.png), on: [dir])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.outputs.isEmpty)
    }
    func testPartialBatchReportsEveryInputAndKeepsOriginals() async throws {
        let dir = try folder()
        let good = dir.appendingPathComponent("valid.png"), bad = dir.appendingPathComponent("broken.png")
        let image = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        image.setFillColor(CGColor(gray: 0.5, alpha: 1)); image.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        try ImageIOHelpers.write(image.makeImage()!, to: good, type: .png)
        try Data("invalid".utf8).write(to: bad)
        let original = try Data(contentsOf: good)
        let occupied = dir.appendingPathComponent("valid.jpg")
        try Data("existing".utf8).write(to: occupied)
        let report = await engine.run(.convert(.jpg), on: [good, bad])
        XCTAssertEqual(report.succeededInputs, 1)
        XCTAssertEqual(report.failures.map(\.url), [bad])
        XCTAssertEqual(report.outputs.count, 1)
        XCTAssertEqual(report.outputs.first?.lastPathComponent, "valid 2.jpg")
        XCTAssertEqual(try Data(contentsOf: good), original)
        XCTAssertEqual(try Data(contentsOf: occupied), Data("existing".utf8))
        XCTAssertTrue(report.cancelled.isEmpty)
    }
    func testMixedSelectionUsesCommonTargetsAndNoTools() {
        let catalog = ActionCatalog(capabilities: Capabilities.detect(useExternalTools: false))
        let png = URL(fileURLWithPath: "/example/sample.png"), audio = URL(fileURLWithPath: "/example/music.wav"), pdf = URL(fileURLWithPath: "/example/sample.pdf")
        XCTAssertTrue(catalog.formatActions(for: [png, audio]).isEmpty)
        XCTAssertTrue(catalog.toolActions(for: [png, pdf]).isEmpty)
        XCTAssertTrue(catalog.formatActions(for: [png, pdf]).contains(.convert(.jpg)))
        XCTAssertFalse(catalog.formatActions(for: [png, pdf]).contains(.convert(.pdf)))
        XCTAssertTrue(catalog.formats(for: URL(fileURLWithPath: "/example/vector.svg")).isEmpty)
    }
    func testBatchVideoDoesNotOfferUnparameterizedTrim() {
        let catalog = ActionCatalog(capabilities: Capabilities.detect())
        let files = [URL(fileURLWithPath: "/example/a.mp4"), URL(fileURLWithPath: "/example/b.mp4")]
        XCTAssertFalse(catalog.toolActions(for: files).contains(.tool(.trim)))
        XCTAssertTrue(catalog.toolActions(for: [files[0]]).contains(.tool(.trim)))
    }
    func testCancellationAccountsForAllUnstartedInputs() async {
        let inputs = [URL(fileURLWithPath: "/example/a.png"), URL(fileURLWithPath: "/example/b.png")]
        let engine = self.engine
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await engine.run(.convert(.jpg), on: inputs)
        }
        task.cancel()
        let report = await task.value
        XCTAssertEqual(report.cancelled, inputs)
        XCTAssertEqual(report.succeededInputs, 0)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.outputs.isEmpty)
    }
    func testFailedWritePublishesNothing() throws {
        let dir = try folder(), target = dir.appendingPathComponent("finished.txt")
        XCTAssertThrowsError(try OutputNaming.write(to: target) { url in
            try Data("partial".utf8).write(to: url)
            throw KumquatError.encodeFailed("test")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testIncompatibleMergeAccountsForEveryInput() async {
        let inputs = [URL(fileURLWithPath: "/example/a.png"), URL(fileURLWithPath: "/example/b.wav")]
        let report = await engine.run(.tool(.merge), on: inputs)
        XCTAssertEqual(report.failures.map(\.url), inputs)
        XCTAssertEqual(report.succeededInputs, 0)
        XCTAssertTrue(report.outputs.isEmpty)
    }

    func testMergeCancellationIsNotReportedAsFailure() async throws {
        let dir = try folder()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        var inputs: [URL] = []
        for name in ["first", "second"] {
            let url = dir.appendingPathComponent(name + ".pdf")
            let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
            inputs.append(url)
        }
        let original = try inputs.map { try Data(contentsOf: $0) }
        let engine = self.engine
        let task = Task { [inputs] in
            await engine.run(.tool(.merge), on: inputs) { completed, _ in
                // Cancel after run's initial cancellation check, before PDFTools starts its pages.
                if completed == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = await task.value
        XCTAssertEqual(report.cancelled, inputs)
        XCTAssertEqual(report.succeededInputs, 0)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.outputs.isEmpty)
        XCTAssertEqual(try inputs.map { try Data(contentsOf: $0) }, original)
    }

    /// A real FFmpeg fixture and wrapper let us stop at an exact segment boundary. Only the
    /// second segment is delayed or failed; the first segment is genuinely encoded and probed.
    private func splitFixture(stoppingWithFailure: Bool) async throws -> (URL, URL, URL, URL, Capabilities) {
        guard let ffmpeg = ExternalTools.locate("ffmpeg"), ExternalTools.locate("ffprobe") != nil else {
            throw XCTSkip("FFmpeg and ffprobe are required for the segment outcome regressions")
        }
        let dir = try folder()
        let first = dir.appendingPathComponent("interrupted.mp4")
        let second = dir.appendingPathComponent("complete.mp4")
        try await ExternalTools.runChecked(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=10", "-t", "2.4", "-c:v", "libx264",
            "-pix_fmt", "yuv420p", first.path])
        try FileManager.default.copyItem(at: first, to: second)
        let marker = dir.appendingPathComponent("second-segment-entered")
        let wrapper = dir.appendingPathComponent("ffmpeg-wrapper")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let stop = stoppingWithFailure
            ? "printf '%s\\n' 'injected segment failure' >&2; exit 23"
            : "exec /bin/sleep 30"
        let script = """
        #!/bin/sh
        for arg do
          case "$arg" in
            *"interrupted Part 002.mp4"*)
              printf '%s\\n' entered > \(quoted(marker.path))
              \(stop)
              ;;
          esac
        done
        exec \(quoted(ffmpeg.path)) "$@"
        """
        try script.write(to: wrapper, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let caps = Capabilities(canWriteHEIC: false, canWriteAVIF: false, ffmpegURL: wrapper, cwebpURL: nil)
        return (first, second, marker, ffmpeg, caps)
    }

    func testCancelledSplitReportsCommittedSegmentAndEveryUnfinishedInput() async throws {
        let (first, second, marker, ffmpeg, capabilities) = try await splitFixture(stoppingWithFailure: false)
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        var engine = ConversionEngine(capabilities: capabilities, options: .init())
        engine.parameters.end = 1
        let worker = Task { [engine] in await engine.run(.tool(.split), on: [first, second]) }
        var reachedSecondSegment = false
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: marker.path) { reachedSecondSegment = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        worker.cancel()
        let report = await worker.value
        XCTAssertTrue(reachedSecondSegment, "The first segment must be committed before cancellation")
        XCTAssertEqual(report.outputs.count, 1)
        XCTAssertEqual(report.outputs.first?.lastPathComponent, "interrupted Part 001.mp4")
        XCTAssertEqual(report.cancelled, [first, second])
        XCTAssertEqual(report.succeededInputs, 0)
        XCTAssertTrue(report.failures.isEmpty)
        let saved = try XCTUnwrap(report.outputs.first)
        let info = try await MediaOperations.probe(saved, ffmpeg: ffmpeg)
        XCTAssertEqual(info.duration, 1, accuracy: 0.05)
        XCTAssertTrue(info.video)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().appendingPathComponent("interrupted Part 002.mp4").path))
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
    }

    func testFailedSplitKeepsCommittedSegmentAndContinuesNextInputWithoutOverwriting() async throws {
        let (first, second, _, ffmpeg, capabilities) = try await splitFixture(stoppingWithFailure: true)
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let occupied = first.deletingLastPathComponent().appendingPathComponent("interrupted Part 001.mp4")
        let existing = Data("pre-existing file".utf8)
        try existing.write(to: occupied)
        var engine = ConversionEngine(capabilities: capabilities, options: .init())
        engine.parameters.end = 1
        let report = await engine.run(.tool(.split), on: [first, second])
        XCTAssertEqual(report.failures.map(\.url), [first])
        XCTAssertTrue(report.failures.first?.message.contains("23") == true)
        XCTAssertEqual(report.succeededInputs, 1)
        XCTAssertTrue(report.cancelled.isEmpty)
        XCTAssertEqual(report.outputs.count, 4)
        XCTAssertEqual(report.outputs.first?.lastPathComponent, "interrupted Part 001 2.mp4")
        var totalDuration = 0.0
        for output in report.outputs {
            let info = try await MediaOperations.probe(output, ffmpeg: ffmpeg)
            XCTAssertTrue(info.video)
            totalDuration += info.duration
        }
        XCTAssertEqual(totalDuration, 3.4, accuracy: 0.1)
        XCTAssertEqual(try Data(contentsOf: occupied), existing)
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
    }
}

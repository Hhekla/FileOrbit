import Foundation
import XCTest
@testable import KumquatCore

/// Synthetic fixtures and outputs are intentionally retained for inspection.
final class MediaRegressionTests: XCTestCase {
    private var ffmpeg: URL { ExternalTools.locate("ffmpeg") ?? URL(fileURLWithPath: "/nonexistent/ffmpeg") }
    private var capabilities: Capabilities {
        .init(canWriteHEIC: false, canWriteAVIF: false, ffmpegURL: ffmpeg, cwebpURL: nil)
    }
    private func directory() throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("FFmpeg is not installed") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileOrbit-MediaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(_ directory: URL, video: Bool = false, audio: Bool = true, name: String = "sample") async throws -> URL {
        let file = directory.appendingPathComponent(name).appendingPathExtension(video ? "mp4" : "wav")
        var args = MediaOperations.common
        if video { args += ["-f", "lavfi", "-i", "testsrc2=size=160x120:rate=20:duration=1.6"] }
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1.6"] }
        if video { args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] }
        if audio { args += ["-c:a", video ? "aac" : "pcm_s16le"] }
        try await ExternalTools.runChecked(ffmpeg, args + [file.path])
        return file
    }
    private func output(_ tool: ToolKind, _ inputs: [URL], _ parameters: ToolParameters = .init()) async throws -> URL {
        let results = try await MediaOperations.run(tool, inputs: inputs, parameters: parameters, capabilities: capabilities)
        return try XCTUnwrap(results.first)
    }

    func testAudioSpeedChannelsJoinAndSourcePreserved() async throws {
        let dir = try directory()
        let source = try await fixture(dir)
        let original = try Data(contentsOf: source)
        var p = ToolParameters()
        p.speed = 2
        let speed = try await output(.speed, [source], p)
        let sped = try await MediaOperations.probe(speed, ffmpeg: ffmpeg)
        XCTAssertEqual(sped.duration, 0.8, accuracy: 0.08)
        p.channels = 2
        let stereo = try await output(.channels, [source], p)
        let stereoInfo = try await MediaOperations.probe(stereo, ffmpeg: ffmpeg)
        XCTAssertEqual(stereoInfo.channels, 2)
        let joined = try await output(.join, [source, source])
        let joinedInfo = try await MediaOperations.probe(joined, ffmpeg: ffmpeg)
        XCTAssertEqual(joinedInfo.duration, 3.2, accuracy: 0.1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNotEqual(source, speed)
    }

    func testVideoJoinRetainsSilentClipsAndCropDimensions() async throws {
        let dir = try directory()
        let first = try await fixture(dir, video: true, name: "sound")
        let second = try await fixture(dir, video: true, audio: false, name: "silent")
        let joined = try await output(.join, [first, second])
        let joinedInfo = try await MediaOperations.probe(joined, ffmpeg: ffmpeg)
        XCTAssertEqual(joinedInfo.duration, 3.2, accuracy: 0.15)
        XCTAssertTrue(joinedInfo.audio)
        var p = ToolParameters()
        p.width = 80; p.height = 60; p.x = 20; p.y = 20
        let cropped = try await output(.crop, [first], p)
        let info = try await MediaOperations.probe(cropped, ffmpeg: ffmpeg)
        XCTAssertEqual(info.width, 80)
        XCTAssertEqual(info.height, 60)
    }

    func testBleepAndNormalizationRetainDuration() async throws {
        let dir = try directory()
        let source = try await fixture(dir)
        var p = ToolParameters(); p.start = 0.3; p.end = 0.8
        for tool in [ToolKind.bleep, .mute, .normalize] {
            let result = try await output(tool, [source], p)
            let info = try await MediaOperations.probe(result, ffmpeg: ffmpeg)
            XCTAssertEqual(info.duration, 1.6, accuracy: 0.08)
            XCTAssertTrue(info.audio)
        }
    }

    func testBleepReplacesSelectedSoundAndMuteIsQuiet() async throws {
        let dir = try directory()
        let source = try await fixture(dir)
        var p = ToolParameters(); p.start = 0.3; p.end = 1.2
        let bleep = try await output(.bleep, [source], p)
        let mute = try await output(.mute, [source], p)
        func samples(_ input: URL, name: String) async throws -> [Int16] {
            let raw = dir.appendingPathComponent(name + ".pcm")
            try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-ss", "0.5", "-i", input.path,
                "-t", "0.3", "-vn", "-ar", "8000", "-ac", "1", "-f", "s16le", raw.path])
            let data = try Data(contentsOf: raw)
            return stride(from: 0, to: data.count - 1, by: 2).map { i in
                Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8))
            }
        }
        let tone = try await samples(bleep, name: "bleep-interval")
        let silence = try await samples(mute, name: "mute-interval")
        let crossings = zip(tone, tone.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }.count
        XCTAssertEqual(Double(crossings) / 0.3, 1000, accuracy: 25, "Selected interval contains a 1 kHz replacement tone")
        XCTAssertLessThan(silence.map { abs(Int($0)) }.max() ?? Int.max, 25, "Selected interval is effectively silent")
    }

    func testSplitRetainsWholeDurationAndTargetSizeIsEnforced() async throws {
        let dir = try directory()
        let source = try await fixture(dir, video: true)
        var p = ToolParameters(); p.end = 0.6
        let parts = try await MediaOperations.run(.split, inputs: [source], parameters: p, capabilities: capabilities)
        XCTAssertEqual(parts.count, 3)
        var duration = 0.0
        for part in parts { duration += try await MediaOperations.probe(part, ffmpeg: ffmpeg).duration }
        XCTAssertEqual(duration, 1.6, accuracy: 0.15)
        p.targetMegabytes = 0.05
        let result = try await output(.targetSize, [source], p)
        XCTAssertLessThanOrEqual(FileClassifier.fileSize(of: result), 50_000)
        let info = try await MediaOperations.probe(result, ffmpeg: ffmpeg)
        XCTAssertEqual(info.duration, 1.6, accuracy: 0.1)
    }

    func testAddedFormatsContainRealMediaStreams() async throws {
        let dir = try directory()
        let source = try await fixture(dir, video: true)
        for format in [OutputFormat.mkv, .avi, .wmv] {
            let results = try await VideoConverter.convert(source, to: format, options: .init(), capabilities: capabilities)
            let result = try XCTUnwrap(results.first)
            let info = try await MediaOperations.probe(result, ffmpeg: ffmpeg)
            XCTAssertTrue(info.video, format.title)
            XCTAssertTrue(info.audio, format.title)
            XCTAssertGreaterThan(info.duration, 1.4, format.title)
        }
        for format in [OutputFormat.ogg, .opus, .wma] {
            let results = try await AudioConverter.convert(source, to: format, capabilities: capabilities)
            let result = try XCTUnwrap(results.first)
            let info = try await MediaOperations.probe(result, ffmpeg: ffmpeg)
            XCTAssertTrue(info.audio, format.title)
            XCTAssertFalse(info.video, format.title)
            XCTAssertGreaterThan(info.duration, 1.4, format.title)
        }
    }

    func testRejectsInvalidRangeAndGIFTruncation() async throws {
        let dir = try directory()
        let source = try await fixture(dir)
        var p = ToolParameters(); p.start = 1; p.end = 0.5
        do {
            _ = try await output(.bleep, [source], p)
            XCTFail("Invalid time range must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("时间范围")) }
        XCTAssertThrowsError(try VideoConverter.validateGIF(duration: 31, options: .init())) { error in
            XCTAssertTrue(error.localizedDescription.contains("截断"))
        }
        XCTAssertThrowsError(try VideoConverter.validateGIF(duration: .infinity, options: .init()))
    }

    func testExternalProcessCapturesTailAndExitCode() async throws {
        let result = try await ExternalTools.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf output; printf diagnostic >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.standardOutput, "output")
        XCTAssertEqual(result.standardError, "diagnostic")
        do {
            try await ExternalTools.runChecked(URL(fileURLWithPath: "/bin/sh"), ["-c", "exit 9"])
            XCTFail("Nonzero exit code must fail even with no stderr")
        } catch { XCTAssertTrue(error.localizedDescription.contains("9")) }
    }

    func testMissingEncoderReportsExplicitFailure() async throws {
        let dir = try directory()
        let source = try await fixture(dir)
        do {
            try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-i", source.path,
                "-c:a", "fileorbit_nonexistent_encoder", dir.appendingPathComponent("missing.m4a").path])
            XCTFail("Missing encoder must never report success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("缺少所需编码器")) }
    }

    func testCancellationStopsExternalProcessPromptly() async throws {
        let start = Date()
        let task = Task { try await ExternalTools.run(URL(fileURLWithPath: "/bin/sleep"), ["20"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}

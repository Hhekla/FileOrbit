import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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

    func testWMVToMOVRetainsDecodablePictureAndSound() async throws {
        let dir = try directory()
        let source = try await fixture(dir, video: true)
        let wmv = dir.appendingPathComponent("windows-media.wmv")
        try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-i", source.path,
            "-c:v", "wmv2", "-c:a", "wmav2", "-ar", "44100", "-ac", "2", wmv.path])
        let original = try Data(contentsOf: wmv)
        let outputs = try await VideoConverter.convert(wmv, to: .mov, options: .init(), capabilities: capabilities)
        let result = try XCTUnwrap(outputs.first)
        // FFmpeg accepts a MOV containing unrecognized WMAv2 audio when stream
        // copying. Require the result to actually decode, including its sound.
        try await ExternalTools.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-xerror", "-i", result.path,
            "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-"])
        let info = try await MediaOperations.probe(result, ffmpeg: ffmpeg)
        XCTAssertTrue(info.video)
        XCTAssertTrue(info.audio)
        XCTAssertEqual(info.duration, 1.6, accuracy: 0.1)
        XCTAssertEqual(try Data(contentsOf: wmv), original)
    }

    func testMPEGAndTransportStreamAudioCanBecomeFLAC() async throws {
        let dir = try directory()
        let source = try await fixture(dir, video: true)
        for ext in ["mpg", "ts"] {
            let input = dir.appendingPathComponent("container").appendingPathExtension(ext)
            let encoding = ext == "mpg"
                ? ["-c:v", "mpeg2video", "-r", "25", "-c:a", "mp2", "-f", "mpeg"]
                : ["-c:v", "libx264", "-c:a", "aac", "-f", "mpegts"]
            try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-i", source.path] + encoding + [input.path])
            let original = try Data(contentsOf: input)
            let outputs = try await AudioConverter.convert(input, to: .flac, capabilities: capabilities)
            let output = try XCTUnwrap(outputs.first)
            try await ExternalTools.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-xerror", "-i", output.path,
                "-map", "0:a:0", "-f", "null", "-"])
            let info = try await MediaOperations.probe(output, ffmpeg: ffmpeg)
            XCTAssertTrue(info.audio)
            XCTAssertFalse(info.video)
            XCTAssertEqual(info.duration, 1.6, accuracy: 0.15)
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testSurroundConversionPreservesSixChannels() async throws {
        let dir = try directory()
        let source = dir.appendingPathComponent("surround.wav")
        try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-f", "lavfi", "-i",
            "aevalsrc=0.1*sin(2*PI*220*t)|0.1*sin(2*PI*330*t)|0.1*sin(2*PI*440*t)|0.1*sin(2*PI*60*t)|0.1*sin(2*PI*660*t)|0.1*sin(2*PI*880*t):s=48000:d=1.6:c=5.1",
            "-c:a", "pcm_s16le", source.path])
        let original = try Data(contentsOf: source)
        for format in [OutputFormat.m4a, .aiff, .flac] {
            let outputs = try await AudioConverter.convert(source, to: format, capabilities: capabilities)
            let output = try XCTUnwrap(outputs.first)
            try await ExternalTools.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-xerror", "-i", output.path,
                "-map", "0:a:0", "-f", "null", "-"])
            let info = try await MediaOperations.probe(output, ffmpeg: ffmpeg)
            XCTAssertEqual(info.channels, 6, format.title)
            XCTAssertEqual(info.duration, 1.6, accuracy: 0.1)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testNativeAudioExportDoesNotMixAlternativeLanguageTracks() async throws {
        let dir = try directory()
        let source = dir.appendingPathComponent("languages.mp4")
        try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-f", "lavfi", "-i",
            "testsrc2=size=160x120:rate=20:duration=1.6", "-f", "lavfi", "-i",
            "sine=frequency=440:sample_rate=48000:duration=1.6", "-f", "lavfi", "-i",
            "sine=frequency=880:sample_rate=48000:duration=1.6", "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", source.path])
        let outputs = try await AudioConverter.convert(source, to: .wav, capabilities: capabilities)
        let output = try XCTUnwrap(outputs.first)
        let raw = dir.appendingPathComponent("selected-track.pcm")
        try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-i", output.path,
            "-ar", "8000", "-ac", "1", "-f", "s16le", raw.path])
        let data = try Data(contentsOf: raw)
        let samples = stride(from: 4000, to: min(data.count - 1, 12000), by: 2).map { i in
            Double(Int16(bitPattern: UInt16(data[i]) | (UInt16(data[i + 1]) << 8))) / 32768
        }
        func power(_ frequency: Double) -> Double {
            let coefficient = 2 * cos(2 * .pi * frequency / 8000)
            var s1 = 0.0, s2 = 0.0
            for sample in samples {
                let s0 = sample + coefficient * s1 - s2
                s2 = s1; s1 = s0
            }
            return sqrt(max(0, s1 * s1 + s2 * s2 - coefficient * s1 * s2))
        }
        XCTAssertGreaterThan(power(440), 10)
        XCTAssertLessThan(power(880) / power(440), 0.06, "The second language track must not be mixed into the first")
        let warnings = await MediaSupport.conversionWarnings(for: source, to: .wav, capabilities: capabilities)
        XCTAssertTrue(warnings.contains { $0.contains("第一条音轨") })
    }

    func testAnimatedMP4RetainsUnequalFinalFrameDuration() async throws {
        let dir = try directory()
        for delays in [[0.2, 0.4], [0.4, 0.2]] {
            let input = dir.appendingPathComponent("timing-\(delays[0]).gif")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL,
                UTType.gif.identifier as CFString, 2, nil))
            for (index, delay) in delays.enumerated() {
                let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                context.setFillColor(index == 0 ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                                               : CGColor(red: 0, green: 1, blue: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let original = try Data(contentsOf: input)
            let outputs = try await ImageConverter.convert(input, to: .mp4, options: .init(), capabilities: capabilities)
            let result = try XCTUnwrap(outputs.first)
            let info = try await MediaOperations.probe(result, ffmpeg: ffmpeg)
            XCTAssertEqual(info.duration, 0.6, accuracy: 0.005)
            let tail = dir.appendingPathComponent("tail-\(delays[0]).rgb")
            try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-i", result.path,
                "-vf", "fps=20", "-ss", "0.55", "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", tail.path])
            let pixels = try Data(contentsOf: tail)
            XCTAssertEqual(pixels.count, 32 * 32 * 3, "The final frame must still be visible at 0.55 seconds")
            if pixels.count >= 3 {
                XCTAssertGreaterThan(Int(pixels[1]), 200, "The end of the clip retains the green final frame")
                XCTAssertLessThan(Int(pixels[0]), 40)
            }
            XCTAssertEqual(try Data(contentsOf: input), original)
        }
    }

    func testAnimatedMP4RetainsThreeAndFourVariableFrameDurations() async throws {
        let dir = try directory()
        let timings = [[0.1, 0.3, 0.6], [0.6, 0.3, 0.1], [0.1, 0.4, 0.2, 0.3]]
        let colors: [[CGFloat]] = [[1, 0, 0], [0, 0, 1], [0, 1, 0], [1, 1, 0]]
        for (variant, delays) in timings.enumerated() {
            let source = dir.appendingPathComponent("variable-frames-\(variant).gif")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL,
                UTType.gif.identifier as CFString, delays.count, nil))
            for (index, delay) in delays.enumerated() {
                let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                let color = colors[index]
                context.setFillColor(CGColor(red: color[0], green: color[1], blue: color[2], alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
                CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let outputs = try await ImageConverter.convert(source, to: .mp4, options: .init(), capabilities: capabilities)
            let output = try XCTUnwrap(outputs.first)
            let info = try await MediaOperations.probe(output, ffmpeg: ffmpeg)
            XCTAssertEqual(info.duration, delays.reduce(0, +), accuracy: 0.005)
            var start = 0.0
            for (index, delay) in delays.enumerated() {
                let sample = dir.appendingPathComponent("color-\(variant)-\(index).rgb")
                try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-i", output.path,
                    "-ss", String(start + delay / 2), "-frames:v", "1", "-vf", "fps=100,scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", sample.path])
                // DeviceRGB can be color-converted while the GIF fixture is
                // encoded. Compare against its actual independently decoded
                // pixels, not the pre-encoding nominal RGB components.
                let sourceSample = dir.appendingPathComponent("source-color-\(variant)-\(index).rgb")
                try await ExternalTools.runChecked(ffmpeg, MediaOperations.common + ["-i", source.path,
                    "-ss", String(start + delay / 2), "-frames:v", "1", "-vf", "fps=100,scale=1:1", "-pix_fmt", "rgb24", "-f", "rawvideo", sourceSample.path])
                let pixels = try Data(contentsOf: sample)
                let expected = try Data(contentsOf: sourceSample)
                XCTAssertEqual(pixels.count, 3)
                XCTAssertEqual(expected.count, 3)
                if pixels.count == 3 && expected.count == 3 {
                    for channel in 0..<3 {
                        XCTAssertEqual(Double(pixels[channel]), Double(expected[channel]), accuracy: 30,
                            "Frame \(index) must remain visible for its own delay")
                    }
                }
                start += delay
            }
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

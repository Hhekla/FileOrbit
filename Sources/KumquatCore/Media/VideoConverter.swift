@preconcurrency import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum VideoConverter {
    public static func convert(_ input: URL, to format: OutputFormat, options: ConversionOptions,
                               capabilities: Capabilities) async throws -> [URL] {
        switch format {
        case .m4a, .mp3, .wav, .aiff, .flac, .ogg, .opus, .wma:
            return try await AudioConverter.convert(input, to: format, capabilities: capabilities)
        case .gif:
            let destination = OutputNaming.convertedURL(for: input, ext: "gif")
            if await MediaSupport.isReadable(input) {
                return [try await OutputNaming.write(to: destination) { try await makeGIF(from: input, to: $0, options: options) }]
            }
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.unsupportedInput(input.lastPathComponent) }
            let info = try await MediaOperations.probe(input, ffmpeg: ffmpeg)
            try validateGIF(duration: info.duration, options: options)
            let size = options.gifMaxWidth
            let filter = "fps=\(options.gifFrameRate),scale='if(gt(iw,ih),\(size),-2)':'if(gt(iw,ih),-2,\(size))':flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"
            return [try await OutputNaming.write(to: destination) { out in
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-loglevel", "error", "-i", input.path, "-vf", filter, "-loop", "0", out.path])
            }]
        case .mp4, .mov:
            return [try await convertContainer(input, to: format, capabilities: capabilities)]
        case .webm, .mkv, .avi, .wmv:
            guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.toolMissing("ffmpeg") }
            let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
            return [try await OutputNaming.write(to: destination) { out in
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-nostdin", "-loglevel", "error", "-i", input.path,
                                                            "-map", "0:v:0", "-map", "0:a:0?"]
                    + ffmpegVideoArguments(format) + [out.path])
            }]
        default:
            throw KumquatError.unsupportedConversion(from: input.pathExtension.uppercased(), to: format.title)
        }
    }

    static func ffmpegVideoArguments(_ format: OutputFormat) -> [String] {
        switch format {
        case .webm: return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-deadline", "good", "-cpu-used", "4", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case .mkv: return ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        case .avi: return ["-c:v", "mpeg4", "-q:v", "3", "-pix_fmt", "yuv420p", "-c:a", "libmp3lame", "-b:a", "192k"]
        case .wmv: return ["-c:v", "wmv2", "-b:v", "3000k", "-pix_fmt", "yuv420p", "-c:a", "wmav2", "-b:a", "192k", "-ar", "44100", "-ac", "2"]
        default: return []
        }
    }

    static func validateGIF(duration: Double, options: ConversionOptions) throws {
        guard duration.isFinite, duration > 0, options.gifMaxDuration.isFinite, options.gifMaxDuration > 0,
              options.gifFrameRate.isFinite, (1...60).contains(options.gifFrameRate),
              (1...4096).contains(options.gifMaxWidth) else {
            throw KumquatError.processFailed("GIF 参数无效；请使用有效时长、1–60 fps 和不超过 4096 的尺寸。")
        }
        guard duration <= options.gifMaxDuration + 0.01 else {
            throw KumquatError.processFailed("视频长 \(String(format: "%.1f", duration)) 秒，超过 GIF 的 \(options.gifMaxDuration) 秒保护上限。请先截取所需片段；未生成被静默截断的 GIF。")
        }
        guard ceil(duration * options.gifFrameRate) <= 10000 else {
            throw KumquatError.processFailed("GIF 超过 10000 帧，请先缩短片段或降低帧率。")
        }
    }

    /// MP4 ⇄ MOV. Rewraps without re-encoding whenever the codecs allow it.
    static func convertContainer(_ input: URL, to format: OutputFormat, capabilities: Capabilities) async throws -> URL {
        let destination = OutputNaming.convertedURL(for: input, ext: format.fileExtension)
        let fileType: AVFileType = format == .mp4 ? .mp4 : .mov

        if await MediaSupport.isReadable(input) {
            let asset = AVURLAsset(url: input)
            let passthrough = await AVAssetExportSession.compatibility(
                ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType)
            let preset = passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
                throw KumquatError.encodeFailed(destination.lastPathComponent)
            }
            return try await OutputNaming.write(to: destination) { out in
                try await MediaSupport.export(session, to: out, as: fileType)
            }
        }

        guard let ffmpeg = capabilities.ffmpegURL else {
            throw KumquatError.unsupportedInput("\(input.lastPathComponent) (install ffmpeg to open it)")
        }
        return try await OutputNaming.write(to: destination) { out in
            // Try a lossless rewrap first (e.g. MKV with H.264 + AAC), then fall back to re-encoding.
            let copy = try await ExternalTools.run(ffmpeg, ["-y", "-nostdin", "-loglevel", "error", "-i", input.path,
                                                            "-map", "0:v:0", "-map", "0:a:0?",
                                                            "-c", "copy", "-movflags", "+faststart", out.path])
            // Some muxers accept codec tags they cannot read back (for example
            // WMAv2 audio in MOV). A zero exit status alone is not a valid file.
            let decodable: Bool
            if copy.status == 0 {
                let check = try await ExternalTools.run(ffmpeg, ["-nostdin", "-loglevel", "error", "-xerror",
                    "-i", out.path, "-map", "0:v:0", "-map", "0:a:0?", "-t", "0.1", "-f", "null", "-"])
                decodable = check.status == 0
            } else {
                decodable = false
            }
            if !decodable {
                try await ExternalTools.runChecked(ffmpeg, ["-y", "-nostdin", "-loglevel", "error", "-i", input.path,
                                                            "-map", "0:v:0", "-map", "0:a:0?",
                                                            "-c:v", "libx264", "-crf", "20", "-preset", "medium",
                                                            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
                                                            "-movflags", "+faststart", out.path])
            }
        }
    }

    /// Animated GIF of the entire clip. Longer-than-limit clips fail explicitly.
    static func makeGIF(from input: URL, to output: URL, options: ConversionOptions) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        try validateGIF(duration: duration, options: options)
        let length = duration
        let fps = options.gifFrameRate
        let count = max(1, Int(ceil(length * fps)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let size = CGFloat(options.gifMaxWidth)
        generator.maximumSize = CGSize(width: size, height: size)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw KumquatError.encodeFailed(output.lastPathComponent)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            let image = try result.image
            CGImageDestinationAddImage(dest, image, frameProps)
            added += 1
        }
        guard added == count, CGImageDestinationFinalize(dest) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
    }
}

/// Animated GIF / WebP / PNG → H.264 MP4.
public enum AnimatedImageVideo {
    public static func writeMP4(from input: URL, to output: URL) async throws {
        let src = try ImageIOHelpers.source(input)
        let count = CGImageSourceGetCount(src)
        guard let first = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        let width = max(2, first.width & ~1), height = max(2, first.height & ~1)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(800_000, width * height * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // Reordered B frames can make VideoToolbox replace the final
                // variable sample duration with the preceding frame's delay.
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw KumquatError.encodeFailed(output.lastPathComponent) }
        writer.add(input)
        guard writer.startWriting() else {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Couldn't start writing.")
        }
        writer.startSession(atSourceTime: .zero)
        defer { if writer.status == .writing { writer.cancelWriting() } }

        var time = 0.0
        for i in 0..<count {
            try Task.checkCancellation()
            guard let frame = CGImageSourceCreateImageAtIndex(src, i, nil) else { throw KumquatError.decodeFailed("frame \(i + 1)") }
            let delay = count > 1 ? ImageConverter.frameDelay(ImageIOHelpers.properties(src, index: i)) : 1
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw KumquatError.encodeFailed(output.lastPathComponent) }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let buffer = pixelBuffer(for: frame, width: width, height: height),
                  let sample = timedSample(buffer, start: time, duration: delay), input.append(sample) else {
                throw KumquatError.encodeFailed("frame \(i + 1)")
            }
            time += delay
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        await writer.finishWriting()
        if writer.status != .completed {
            throw KumquatError.processFailed(writer.error?.localizedDescription ?? "Couldn't write the video.")
        }
    }

    /// Pixel-buffer adaptors omit sample duration, so the final animation frame
    /// can inherit the preceding delay and truncate a variable-timing GIF.
    static func timedSample(_ buffer: CVPixelBuffer, start: Double, duration: Double) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: buffer, formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 600),
                                       presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    static func pixelBuffer(for image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: ImageIOHelpers.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        // Transparent GIF pixels have no video equivalent; show them as white.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

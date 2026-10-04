import Foundation

/// Local, explicitly parameterized media operations powered by an installed FFmpeg.
/// Outputs are newly named files beside the source; original files are never changed.
public enum MediaOperations {
    public static func run(_ tool: ToolKind, inputs: [URL], parameters: ToolParameters,
                           capabilities: Capabilities) async throws -> [URL] {
        guard !inputs.isEmpty else { throw KumquatError.nothingToDo("请先选择影音文件。") }
        guard let ffmpeg = capabilities.ffmpegURL else { throw KumquatError.toolMissing("ffmpeg") }
        if tool == .join { return [try await join(inputs, ffmpeg: ffmpeg)] }
        var results: [URL] = []
        do {
            for input in inputs {
                try Task.checkCancellation()
                let info = try await probe(input, ffmpeg: ffmpeg)
                if tool == .split {
                    results += try await split(input, info: info, seconds: parameters.end, ffmpeg: ffmpeg)
                } else {
                    results.append(try await operate(tool, input: input, info: info, p: parameters, ffmpeg: ffmpeg))
                }
            }
            return results
        } catch {
            guard !results.isEmpty else { throw error }
            throw PartialOutputError(outputs: results, underlyingError: error, cancelled: Task.isCancelled)
        }
    }

    struct Info: Sendable {
        let duration: Double
        let video: Bool
        let audio: Bool
        let width: Int
        let height: Int
        let channels: Int
    }

    static func probe(_ input: URL, ffmpeg: URL) async throws -> Info {
        let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard let ffprobe = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : ExternalTools.locate("ffprobe") else {
            throw KumquatError.toolMissing("ffprobe（随 FFmpeg 提供）")
        }
        let result = try await ExternalTools.run(ffprobe, ["-v", "error", "-show_entries",
            "format=duration:stream=codec_type,width,height,channels:stream_disposition=attached_pic", "-of", "json", input.path])
        guard result.status == 0 else {
            throw KumquatError.processFailed("无法检查 \(input.lastPathComponent)：\(result.standardError)")
        }
        struct Probe: Decodable {
            struct Format: Decodable { var duration: String? }
            struct Stream: Decodable {
                struct Disposition: Decodable { var attached_pic: Int? }
                var codec_type: String; var width: Int?; var height: Int?; var channels: Int?; var disposition: Disposition?
            }
            var format: Format?
            var streams: [Stream]
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Probe.self, from: data),
              let duration = Double(parsed.format?.duration ?? ""), duration.isFinite, duration > 0 else {
            throw KumquatError.processFailed("无法确定 \(input.lastPathComponent) 的时长；不执行可能截断内容的操作。")
        }
        let video = parsed.streams.first { $0.codec_type == "video" && $0.disposition?.attached_pic != 1 }
        let audio = parsed.streams.first { $0.codec_type == "audio" }
        guard video != nil || audio != nil else { throw KumquatError.unsupportedInput(input.lastPathComponent) }
        return Info(duration: duration, video: video != nil, audio: audio != nil,
                    width: video?.width ?? 0, height: video?.height ?? 0, channels: audio?.channels ?? 0)
    }

    static let common = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
    static func encoding(video: Bool) -> [String] {
        (video ? ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"] : ["-vn"])
        + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
    }
    static func maps(_ info: Info) -> [String] {
        (info.video ? ["-map", "0:v:0"] : []) + (info.audio ? ["-map", "0:a:0"] : [])
    }
    static func range(_ p: ToolParameters, duration: Double) throws -> (Double, Double) {
        guard p.start.isFinite, p.end.isFinite, p.start >= 0, p.end > p.start, p.end <= duration + 0.02 else {
            throw KumquatError.processFailed("时间范围须满足 0 ≤ 开始 < 结束 ≤ 文件时长（\(String(format: "%.2f", duration)) 秒）。")
        }
        return (p.start, min(p.end, duration))
    }
    static func tempo(_ speed: Double) -> String {
        var value = speed, filters: [String] = []
        while value > 2 { filters.append("atempo=2"); value /= 2 }
        while value < 0.5 { filters.append("atempo=0.5"); value /= 0.5 }
        filters.append("atempo=\(value)")
        return filters.joined(separator: ",")
    }

    private static func operate(_ tool: ToolKind, input: URL, info: Info, p: ToolParameters, ffmpeg: URL) async throws -> URL {
        var arguments = common + ["-i", input.path]
        var mapping = maps(info)
        var filters: [String] = []
        let tag: String
        switch tool {
        case .speed:
            guard p.speed.isFinite, (0.125...8).contains(p.speed) else {
                throw KumquatError.processFailed("播放速度须在 0.125 到 8 倍之间。")
            }
            tag = "Speed \(p.speed)x"
            if info.video { filters += ["-vf", "setpts=(PTS-STARTPTS)/\(p.speed)"] }
            if info.audio { filters += ["-af", tempo(p.speed)] }
        case .normalize:
            guard info.audio else { throw KumquatError.nothingToDo("文件没有音轨，无法标准化音量。") }
            tag = "Normalized"
            filters += ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000"]
        case .channels:
            guard info.audio else { throw KumquatError.nothingToDo("文件没有音轨。") }
            guard [1, 2].contains(p.channels) else { throw KumquatError.processFailed("声道数只能为 1（单声道）或 2（立体声）。") }
            tag = p.channels == 1 ? "Mono" : "Stereo"
            filters += ["-ac", String(p.channels)]
        case .mute, .bleep:
            guard info.audio else { throw KumquatError.nothingToDo("文件没有音轨。") }
            let (start, end) = try range(p, duration: info.duration)
            tag = tool == .mute ? "Silenced" : "Bleeped"
            let enable = "between(t,\(start),\(end))"
            if tool == .mute {
                filters += ["-af", "volume=0:enable='\(enable)'"]
            } else {
                // Synthesized tone is gated to the selected interval; the original is silent there.
                let graph = "[0:a:0]volume=0:enable='\(enable)'[original];sine=frequency=1000:sample_rate=48000:duration=\(info.duration),volume=0.8,volume=0:enable='not(\(enable))'[tone];[original][tone]amix=inputs=2:duration=first:normalize=0[a]"
                filters += ["-filter_complex", graph]
                mapping = (info.video ? ["-map", "0:v:0"] : []) + ["-map", "[a]"]
            }
        case .crop:
            guard info.video else { throw KumquatError.nothingToDo("只有视频可以裁剪画面。") }
            guard p.width >= 2, p.height >= 2, p.width % 2 == 0, p.height % 2 == 0,
                  p.x >= 0, p.y >= 0, p.width <= info.width, p.height <= info.height,
                  p.x <= info.width - p.width, p.y <= info.height - p.height else {
                throw KumquatError.processFailed("裁剪框必须位于 \(info.width) × \(info.height) 画面内，宽高为正偶数。")
            }
            tag = "Cropped"
            filters += ["-vf", "crop=\(p.width):\(p.height):\(p.x):\(p.y)"]
        case .trim:
            let (start, end) = try range(p, duration: info.duration)
            tag = "Trimmed"
            arguments = common + ["-ss", String(start), "-i", input.path, "-t", String(end - start)]
        case .targetSize:
            return try await targetSize(input, info: info, megabytes: p.targetMegabytes, ffmpeg: ffmpeg)
        default:
            throw KumquatError.processFailed("此影音工具尚未实现：\(tool.title)")
        }
        let destination = OutputNaming.taggedURL(for: input, tag: tag, ext: info.video ? "mp4" : "m4a")
        let command = arguments + mapping + filters + encoding(video: info.video)
        return try await OutputNaming.write(to: destination) { output in
            try await ExternalTools.runChecked(ffmpeg, command + [output.path])
        }
    }

    private static func split(_ input: URL, info: Info, seconds: Double, ffmpeg: URL) async throws -> [URL] {
        guard seconds.isFinite, seconds > 0, seconds < info.duration,
              ceil(info.duration / seconds) <= 1000 else {
            throw KumquatError.processFailed("分段长度须大于 0 且小于文件时长，最多生成 1000 段。")
        }
        var results: [URL] = []
        let count = Int(ceil(info.duration / seconds))
        do {
            for index in 0..<count {
                try Task.checkCancellation()
                let start = Double(index) * seconds
                let length = min(seconds, info.duration - start)
                let destination = OutputNaming.taggedURL(for: input, tag: String(format: "Part %03d", index + 1), ext: info.video ? "mp4" : "m4a")
                results.append(try await OutputNaming.write(to: destination) { output in
                    try await ExternalTools.runChecked(ffmpeg, common + ["-ss", String(start), "-i", input.path,
                        "-t", String(length)] + maps(info) + encoding(video: info.video) + [output.path])
                })
            }
        } catch {
            guard !results.isEmpty else { throw error }
            throw PartialOutputError(outputs: results, underlyingError: error, cancelled: Task.isCancelled)
        }
        return results
    }

    private static func join(_ inputs: [URL], ffmpeg: URL) async throws -> URL {
        guard inputs.count >= 2 else { throw KumquatError.nothingToDo("合并需要至少两个影音文件。") }
        var infos: [Info] = []
        for input in inputs { infos.append(try await probe(input, ffmpeg: ffmpeg)) }
        let video = infos[0].video
        guard infos.allSatisfy({ $0.video == video && (video || $0.audio) }) else {
            throw KumquatError.processFailed("请分别合并视频或音频；不支持混合两类文件。")
        }
        let width = max(2, infos[0].width & ~1), height = max(2, infos[0].height & ~1)
        var graph: [String] = [], labels = ""
        // A missing audio track becomes silence, so sequential video merge retains every clip.
        for (i, info) in infos.enumerated() {
            if video {
                graph.append("[\(i):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p,setpts=PTS-STARTPTS[v\(i)]")
                labels += "[v\(i)]"
            }
            if info.audio {
                graph.append("[\(i):a:0]aresample=48000,aformat=channel_layouts=stereo,asetpts=PTS-STARTPTS,apad,atrim=duration=\(info.duration)[a\(i)]")
            } else {
                graph.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(info.duration)[a\(i)]")
            }
            labels += "[a\(i)]"
        }
        graph.append(labels + "concat=n=\(inputs.count):v=\(video ? 1 : 0):a=1" + (video ? "[v][a]" : "[a]"))
        let destination = OutputNaming.taggedURL(for: inputs[0], tag: "Joined", ext: video ? "mp4" : "m4a")
        var command = common
        for input in inputs { command += ["-i", input.path] }
        command += ["-filter_complex", graph.joined(separator: ";")]
        if video { command += ["-map", "[v]"] }
        command += ["-map", "[a]"]
        command += encoding(video: video)
        return try await OutputNaming.write(to: destination) { output in
            try await ExternalTools.runChecked(ffmpeg, command + [output.path])
        }
    }

    private static func targetSize(_ input: URL, info: Info, megabytes: Double, ffmpeg: URL) async throws -> URL {
        guard megabytes.isFinite, megabytes > 0, megabytes <= 1_000_000 else {
            throw KumquatError.processFailed("目标大小须为大于 0 的 MB 数值。")
        }
        let bytes = megabytes * 1_000_000
        var budget = min(250_000_000, bytes * 8 / info.duration * 0.92)
        let audioRate = info.audio ? min(128_000.0, max(24_000, budget * (info.video ? 0.15 : 1))) : 0
        guard budget >= (info.video ? 32_000 + audioRate : 16_000) else {
            throw KumquatError.processFailed("目标大小过小，无法为此时长保留可用的影音码率。请提高目标大小。")
        }
        let destination = OutputNaming.taggedURL(for: input, tag: "Under \(megabytes) MB", ext: info.video ? "mp4" : "m4a")
        return try await OutputNaming.write(to: destination) { output in
            for _ in 0..<3 {
                try Task.checkCancellation()
                var codec: [String] = []
                if info.video {
                    let videoRate = max(16_000, Int(budget - audioRate))
                    codec += ["-c:v", "libx264", "-preset", "medium", "-b:v", String(videoRate), "-maxrate", String(videoRate),
                              "-bufsize", String(videoRate * 2), "-pix_fmt", "yuv420p"]
                } else { codec += ["-vn"] }
                if info.audio { codec += ["-c:a", "aac", "-b:a", String(Int(info.video ? audioRate : min(budget, 256_000))) ] }
                try await ExternalTools.runChecked(ffmpeg, common + ["-i", input.path] + maps(info) + codec + ["-movflags", "+faststart", output.path])
                let actual = Double(FileClassifier.fileSize(of: output))
                if actual > 0, actual <= bytes { return }
                budget *= min(0.85, bytes / max(actual, 1) * 0.9)
                if budget < (info.video ? 16_000 + audioRate : 16_000) { break }
            }
            throw KumquatError.processFailed("未能达到 \(megabytes) MB 的大小上限；没有把超限文件当作成功结果。请增加目标大小或缩短时长。")
        }
    }
}

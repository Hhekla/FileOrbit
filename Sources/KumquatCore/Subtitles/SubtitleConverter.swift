import Foundation

/// Converts real timed cues; plain text is export-only because it contains no timing information.
public enum SubtitleConverter {
    public struct Cue: Equatable, Sendable {
        public var startMilliseconds: Int
        public var endMilliseconds: Int
        public var lines: [String]
    }

    public static func convert(_ input: URL, to format: OutputFormat) throws -> [URL] {
        guard [OutputFormat.srt, .vtt, .txt].contains(format) else {
            throw KumquatError.unsupportedConversion(from: "subtitle", to: format.title)
        }
        guard ["srt", "vtt"].contains(input.pathExtension.lowercased()) else {
            throw KumquatError.processFailed("纯文本没有时间轴，不能自动生成真实对齐的字幕。请提供 SRT 或 VTT。")
        }
        let cues = try parse(DocumentConverter.readPlainText(input), webVTT: input.pathExtension.lowercased() == "vtt")
        let text = render(cues, format: format)
        return [try OutputNaming.write(to: OutputNaming.convertedURL(for: input, ext: format.fileExtension)) {
            try text.write(to: $0, atomically: false, encoding: .utf8)
        }]
    }

    public static func parse(_ source: String, webVTT: Bool) throws -> [Cue] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var lines = text.components(separatedBy: "\n")
        if webVTT {
            guard let header = lines.first, header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t") else {
                throw KumquatError.processFailed("VTT 缺少 WEBVTT 文件头。")
            }
            lines.removeFirst()
            while let line = lines.first, !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        }
        var blocks: [[String]] = [], block: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !block.isEmpty { blocks.append(block); block = [] }
            } else { block.append(line) }
        }
        if !block.isEmpty { blocks.append(block) }
        var cues: [Cue] = []
        for (index, block) in blocks.enumerated() {
            let first = block[0]
            if webVTT && (first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t")) { continue }
            if webVTT && (first == "STYLE" || first == "REGION") {
                throw KumquatError.processFailed("此 VTT 含样式或区域定义，当前版本不能完整保留，已停止转换。")
            }
            let timingIndex = first.contains("-->") ? 0 : 1
            guard timingIndex < block.count else { throw malformed(index) }
            let parts = block[timingIndex].components(separatedBy: "-->")
            guard parts.count == 2 else { throw malformed(index) }
            let endParts = parts[1].trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            // Reject layout loss explicitly instead of silently removing cue positioning.
            guard endParts.count == 1, let ending = endParts.first,
                  let start = milliseconds(parts[0].trimmingCharacters(in: .whitespaces), webVTT: webVTT),
                  let end = milliseconds(String(ending), webVTT: webVTT), end > start,
                  block.count > timingIndex + 1 else { throw malformed(index) }
            cues.append(Cue(startMilliseconds: start, endMilliseconds: end, lines: Array(block.dropFirst(timingIndex + 1))))
        }
        guard !cues.isEmpty else { throw KumquatError.nothingToDo("字幕中没有有效的时间轴片段。") }
        return cues
    }

    public static func render(_ cues: [Cue], format: OutputFormat) -> String {
        if format == .txt { return cues.map { $0.lines.joined(separator: "\n") }.joined(separator: "\n\n") + "\n" }
        let separator = format == .vtt ? "." : ","
        let blocks = cues.enumerated().map { index, cue in
            let timing = "\(timestamp(cue.startMilliseconds, separator: separator)) --> \(timestamp(cue.endMilliseconds, separator: separator))"
            return (format == .srt ? "\(index + 1)\n" : "") + timing + "\n" + cue.lines.joined(separator: "\n")
        }
        return (format == .vtt ? "WEBVTT\n\n" : "") + blocks.joined(separator: "\n\n") + "\n"
    }

    static func milliseconds(_ value: String, webVTT: Bool) -> Int? {
        let pattern = webVTT ? #"^(?:([0-9]{2,}):)?([0-9]{2}):([0-9]{2})\.([0-9]{3})$"# : #"^([0-9]{2,}):([0-9]{2}):([0-9]{2}),([0-9]{3})$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let ns = value as NSString
        func number(_ n: Int) -> Int? { match.range(at: n).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: n))) }
        guard let h = number(1), let m = number(2), let s = number(3), let ms = number(4), m < 60, s < 60,
              h < 1_000_000 else { return nil }
        return ((h * 60 + m) * 60 + s) * 1000 + ms
    }

    static func timestamp(_ value: Int, separator: String) -> String {
        String(format: "%02d:%02d:%02d%@%03d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, separator, value % 1000)
    }
    static func malformed(_ index: Int) -> KumquatError {
        .processFailed("第 \(index + 1) 个字幕块的时间戳、时间顺序或定位设置不受支持；已停止转换，避免丢失内容。")
    }
}

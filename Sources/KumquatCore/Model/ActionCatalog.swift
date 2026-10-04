import Foundation

/// Selection is an intersection, never a first-file filter.
public struct ActionCatalog: Sendable {
    public var capabilities: Capabilities
    public init(capabilities: Capabilities) { self.capabilities = capabilities }
    public func actions(for urls: [URL], mode: WheelMode) -> [WheelAction] {
        if mode == .formats { return formatActions(for: urls) }
        let tools = toolActions(for: urls)
        return tools.isEmpty ? formatActions(for: urls) : tools
    }
    public func formatActions(for urls: [URL]) -> [WheelAction] {
        guard !urls.isEmpty, !urls.contains(where: FileClassifier.isDirectory) else { return [] }
        let common = urls.dropFirst().reduce(formats(for: urls[0])) { prior, url in prior.filter(formats(for: url).contains) }
        return common.map(WheelAction.convert)
    }
    public func formats(for url: URL) -> [OutputFormat] {
        let source = FileClassifier.sourceFormat(of: url)
        let candidates: [OutputFormat]
        switch FileClassifier.kind(of: url) {
        case .image:
            if url.pathExtension.lowercased() == "svg" { return [] }
            candidates = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .pdf, .docx] + (source == .gif ? [.mp4] : [])
        case .pdf: candidates = [.docx, .jpg, .png, .txt]
        case .document: candidates = [.pdf, .docx, .rtf, .txt, .html, .odt, .md]
        case .video: candidates = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .m4a, .mp3, .wav, .flac, .ogg, .opus, .aiff, .wma]
        case .audio: candidates = [.m4a, .mp3, .wav, .flac, .ogg, .opus, .aiff, .wma]
        case .subtitle: candidates = [.srt, .vtt, .txt]
        case .archive: candidates = [.zip, .tar, .gz]
        case .unsupported: candidates = []
        }
        return candidates.filter { $0 != source && capabilities.canProduce($0) }
    }
    public func toolActions(for urls: [URL]) -> [WheelAction] {
        guard !urls.isEmpty, !urls.contains(where: FileClassifier.isDirectory) else { return [] }
        let kinds = Set(urls.map(FileClassifier.kind(of:)))
        guard kinds.count == 1, let kind = kinds.first else { return [] }
        let one = urls.count == 1
        var tools: [ToolKind]
        switch kind {
        case .image:
            if urls.contains(where: { $0.pathExtension.lowercased() == "svg" }) { return [] }
            tools = one ? [.compress, .resize, .metadata, .edit, .annotate, .addBackground, .crop, .redact, .qrCode, .targetSize] : [.compress, .resize, .merge, .collage, .metadata, .qrCode]
        case .pdf: tools = one ? [.compress, .rotate, .split, .reorderPages, .watermark, .metadata] : [.compress, .merge, .rotate]
        case .video:
            tools = one ? [.compress, .trim, .mute, .rotate, .snapshot] : [.compress, .mute, .rotate, .snapshot]
            if capabilities.hasFFmpeg { tools += one ? [.speed, .crop, .split, .targetSize] : [.join] }
            if !capabilities.hasFFmpeg && urls.contains(where: { !["mp4", "m4v", "mov"].contains($0.pathExtension.lowercased()) }) { tools = [] }
        case .audio:
            tools = one ? [.trim, .compress] : [.compress]
            if capabilities.hasFFmpeg { tools += one ? [.speed, .normalize, .bleep, .channels, .targetSize, .split] : [.join, .normalize] }
        case .archive: tools = [.extract]
        case .document, .subtitle, .unsupported: tools = []
        }
        return tools.map(WheelAction.tool)
    }
    public static func needsParameters(_ tool: ToolKind) -> Bool {
        [.resize, .collage, .speed, .join, .normalize, .bleep, .channels, .reorderPages, .targetSize].contains(tool)
    }
    public static func isInteractive(_ tool: ToolKind, kind: FileKind, fileCount: Int) -> Bool {
        if needsParameters(tool) || (kind == .video && [.crop, .split].contains(tool)) || (kind == .audio && tool == .split) { return true }
        guard fileCount == 1 else { return false }
        switch tool {
        case .edit, .annotate, .addBackground, .crop, .redact, .watermark, .trim: return true
        case .metadata: return kind == .image || kind == .pdf
        default: return false
        }
    }
}

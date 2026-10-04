import Foundation

/// A target file format that a dragged file can be converted into.
public enum OutputFormat: String, CaseIterable, Codable, Sendable {
    // Images
    case jpg, png, webp, heic, tiff, avif, bmp, gif, svg
    // Documents
    case pdf, docx, txt, rtf, html, odt, md
    // Audio / video
    case mp4, mov, webm, m4a, mp3, wav, aiff, flac, mkv, avi, wmv, ogg, opus, wma
    case srt, vtt, zip, tar, gz

    /// Short label drawn on the wheel ("JPG", "DOCX", ...).
    public var title: String {
        rawValue.uppercased()
    }

    public var fileExtension: String { rawValue }

    public var isImage: Bool {
        switch self {
        case .jpg, .png, .webp, .heic, .tiff, .avif, .bmp, .gif: return true
        default: return false
        }
    }
}

/// A tool shown on the Option+Shift wheel.
public enum ToolKind: String, CaseIterable, Codable, Sendable {
    // Image tools (the order used on the wheel lives in ActionCatalog)
    case compress, metadata, edit, annotate, addBackground, crop, redact
    // Document / media tools
    case rotate, split, merge, watermark, trim, mute, snapshot
    case resize, collage, qrCode, speed, join, normalize, bleep, channels, reorderPages, targetSize, extract

    /// English label drawn on the wheel. The app layer localizes it.
    public var title: String {
        switch self {
        case .compress: return "COMPRESS"
        case .metadata: return "METADATA"
        case .edit: return "EDIT"
        case .annotate: return "ANNOTATE"
        case .addBackground: return "ADD BG"
        case .crop: return "CROP"
        case .redact: return "REDACT"
        case .rotate: return "ROTATE"
        case .split: return "SPLIT"
        case .merge: return "MERGE"
        case .watermark: return "WATERMARK"
        case .trim: return "TRIM"
        case .mute: return "MUTE"
        case .snapshot: return "SNAPSHOT"
        case .resize: return "RESIZE"
        case .collage: return "COLLAGE"
        case .qrCode: return "READ QR"
        case .speed: return "SPEED"
        case .join: return "JOIN"
        case .normalize: return "NORMALIZE"
        case .bleep: return "BLEEP"
        case .channels: return "CHANNELS"
        case .reorderPages: return "PAGES"
        case .targetSize: return "TARGET SIZE"
        case .extract: return "EXTRACT"
        }
    }

    /// SF Symbol used for the tool's icon.
    public var symbolName: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "tag"
        case .edit: return "slider.horizontal.3"
        case .annotate: return "pencil.tip.crop.circle"
        case .addBackground: return "photo"
        case .crop: return "crop"
        case .redact: return "eye.slash"
        case .rotate: return "rotate.right"
        case .split: return "rectangle.split.2x1"
        case .merge: return "square.stack"
        case .watermark: return "signature"
        case .trim: return "scissors"
        case .mute: return "speaker.slash"
        case .snapshot: return "camera"
        case .resize: return "arrow.up.left.and.arrow.down.right"
        case .collage: return "square.grid.2x2"
        case .qrCode: return "qrcode.viewfinder"
        case .speed: return "speedometer"
        case .join: return "link"
        case .normalize: return "waveform"
        case .bleep: return "speaker.badge.exclamationmark"
        case .channels: return "speaker.wave.2"
        case .reorderPages: return "doc.on.doc"
        case .targetSize: return "arrow.down.circle"
        case .extract: return "archivebox"
        }
    }
}

/// Something the user can drop a file onto.
public enum WheelAction: Hashable, Sendable {
    case convert(OutputFormat)
    case tool(ToolKind)

    public var title: String {
        switch self {
        case .convert(let format): return format.title
        case .tool(let tool): return tool.title
        }
    }

    public var symbolName: String? {
        switch self {
        case .convert: return nil
        case .tool(let tool): return tool.symbolName
        }
    }
}

/// Which wheel is showing.
public enum WheelMode: String, Sendable {
    /// Shift: output formats.
    case formats
    /// Option+Shift: tools.
    case tools
}


import AppKit
import KumquatCore

/// Command-line entry to the same engine used by the desktop UI.
enum CommandLineTool {
    static let commands: Set<String> = ["convert", "tool", "actions", "info", "render-previews", "self-test", "help", "--help", "-h"]
    static func shouldHandle(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        return commands.contains(arguments[1]) || !arguments[1].hasPrefix("-")
    }
    static let usage = """
    FileOrbit — offline file tools for macOS.
      FileOrbit convert <file>... --to <format> [--pdf-mode appearance|editable] [--json]
      FileOrbit tool <tool> <file>... [options] [--json]
      FileOrbit actions <file>...
      FileOrbit info <image>
      FileOrbit render-previews <folder>
      FileOrbit self-test

    Tools: compress resize collage qrCode metadata rotate split merge mute snapshot
           speed join normalize bleep channels targetSize crop trim reorderPages extract
    Options: --width 1280 --height 720 --x 0 --y 0 --columns 2 --padding 16
             --start 0 --end 5 --speed 1.5 --target-mb 10 --channels 1 --pages 3,1-2
    Split uses --end as segment length (seconds). Use -- before paths starting with '-'.
    Files are saved beside the originals, without overwriting. PDF-to-Word defaults to editable text.
    Complex Word layouts reflow. Appearance mode embeds page images that TextEdit cannot display.
    """
    struct Arguments {
        var paths: [String] = []
        var values: [String: String] = [:]
        var json = false
        init(_ args: [String]) throws {
            let known: Set<String> = ["to", "pdf-mode", "width", "height", "x", "y", "columns", "padding", "start", "end", "speed", "target-mb", "channels", "pages"]
            var index = 0, pathsOnly = false
            while index < args.count {
                let arg = args[index]
                if pathsOnly { paths.append(arg) }
                else if arg == "--" { pathsOnly = true }
                else if arg == "--json" { json = true }
                else if arg.hasPrefix("--") {
                    let key = String(arg.dropFirst(2))
                    guard known.contains(key), index + 1 < args.count, values[key] == nil else {
                        throw KumquatError.nothingToDo("Invalid or repeated option: \(arg)")
                    }
                    index += 1; values[key] = args[index]
                } else { paths.append(arg) }
                index += 1
            }
        }
        func parameters() throws -> ToolParameters {
            var p = ToolParameters()
            func int(_ key: String, _ fallback: Int) throws -> Int {
                guard let raw = values[key] else { return fallback }
                guard let value = Int(raw) else { throw KumquatError.nothingToDo("--\(key) requires an integer") }
                return value
            }
            func double(_ key: String, _ fallback: Double) throws -> Double {
                guard let raw = values[key] else { return fallback }
                guard let value = Double(raw), value.isFinite else { throw KumquatError.nothingToDo("--\(key) requires a finite number") }
                return value
            }
            p.width = try int("width", p.width); p.height = try int("height", p.height)
            p.x = try int("x", p.x); p.y = try int("y", p.y)
            p.columns = try int("columns", p.columns); p.padding = try int("padding", p.padding)
            p.channels = try int("channels", p.channels)
            p.start = try double("start", p.start); p.end = try double("end", p.end)
            p.speed = try double("speed", p.speed); p.targetMegabytes = try double("target-mb", p.targetMegabytes)
            p.pages = values["pages"] ?? p.pages
            return p
        }
    }
    @MainActor
    static func run(_ arguments: [String]) async -> Int32 {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else { print(usage); return 64 }
        do {
            switch command {
            case "convert", "tool":
                let parsed = try Arguments(Array(args.dropFirst(command == "tool" ? 2 : 1)))
                guard !parsed.paths.isEmpty else { throw KumquatError.nothingToDo("Choose at least one input file.") }
                var options = AppSettings.shared.conversionOptions
                if let mode = parsed.values["pdf-mode"] {
                    guard ["appearance", "editable"].contains(mode) else { throw KumquatError.nothingToDo("--pdf-mode must be appearance or editable") }
                    options.pdfDocxMode = mode == "editable" ? .editableText : .preserveAppearance
                }
                var engine = ConversionEngine(capabilities: Capabilities.detect(), options: options)
                engine.parameters = try parsed.parameters()
                let action: WheelAction
                if command == "convert" {
                    let raw = parsed.values["to"]?.lowercased()
                    guard let raw, let format = OutputFormat(rawValue: raw == "jpeg" ? "jpg" : raw) else { throw KumquatError.nothingToDo("Specify --to with a valid format.") }
                    action = .convert(format)
                } else {
                    guard args.count > 1, let tool = ToolKind(rawValue: args[1]) else { throw KumquatError.nothingToDo("Unknown tool.\n\(usage)") }
                    if [.trim, .bleep].contains(tool), parsed.values["end"] == nil { throw KumquatError.nothingToDo("--end is required for \(tool.rawValue); specify the interval explicitly.") }
                    action = .tool(tool)
                }
                return report(await engine.run(action, on: parsed.paths.map(fileURL)), json: parsed.json)
            case "actions":
                let catalog = ActionCatalog(capabilities: Capabilities.detect())
                let urls = args.dropFirst().map(fileURL)
                print("Formats (⇧): " + catalog.formatActions(for: urls).map(\.title).joined(separator: "  "))
                print("Tools (⌥⇧):  " + catalog.toolActions(for: urls).map(\.title).joined(separator: "  "))
                return 0
            case "info":
                guard args.count == 2 else { print(usage); return 64 }
                let summary = try ImageMetadata.summary(of: fileURL(args[1]))
                for entry in summary.entries { print("\(entry.section) / \(entry.label): \(entry.value)") }
                return 0
            case "self-test": return SelfTest.run() ? 0 : 1
            case "render-previews":
                guard args.count == 2 else { print(usage); return 64 }
                return PreviewRenderer.renderAll(to: fileURL(args[1])) ? 0 : 1
            case "help", "--help", "-h": print(usage); return 0
            default: print("Unknown command: \(command)\n\(usage)"); return 64
            }
        } catch { print(ConversionEngine.message(for: error)); return 1 }
    }
    static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    static func report(_ report: ConversionEngine.Report, json: Bool = false) -> Int32 {
        if json {
            let result: [String: Any] = ["outputs": report.outputs.map(\.path), "succeededInputs": report.succeededInputs,
                "failures": report.failures.map { ["input": $0.url.path, "message": $0.message] },
                "cancelled": report.cancelled.map(\.path), "warnings": report.warnings]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
        } else {
            for url in report.outputs { print("✓ \(url.path)") }
            for failure in report.failures { print("✗ \(failure.url.lastPathComponent): \(failure.message)") }
            for url in report.cancelled { print("Cancelled: \(url.lastPathComponent)") }
            for warning in report.warnings { print("Note: \(warning)") }
            if let note = report.note { print(note) }
        }
        if !report.cancelled.isEmpty { return 130 }
        return report.failures.isEmpty ? 0 : 1
    }
}

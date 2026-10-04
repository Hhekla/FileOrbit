import AppKit
import Foundation

/// Materializes Word's style inheritance before AppKit reads the package.
/// The native importer reads direct formatting but skips many style definitions.
enum DocxImport {
    static func preparedData(_ input: URL, target: OutputFormat? = nil) throws -> Data {
        var limits = ArchiveConverter.Limits()
        limits.maximumFileBytes = 16 * 1024 * 1024
        limits.maximumTotalBytes = 64 * 1024 * 1024
        limits.maximumEntries = 2_000
        let reader = try ArchiveConverter.Reader(input: input, library: ArchiveLibrary(), limits: limits)
        var files: [(String, Data)] = []
        while let entry = try reader.next() {
            var data = Data()
            while let chunk = try reader.chunk() { data.append(chunk) }
            if !entry.directory { files.append((entry.name, data)) }
        }
        let contents = Dictionary(uniqueKeysWithValues: files)
        guard let bodyData = contents["word/document.xml"] else { throw KumquatError.decodeFailed(input.lastPathComponent) }
        let document = try xml(bodyData)
        let features = unsupportedTextFeatures(contents, document: document)
        guard features.isEmpty else {
            throw KumquatError.processFailed("当前 Word 转换尚不能保留\(features.joined(separator: "、"))，已停止以避免丢失内容。请先在支持完整 Word 排版的编辑器中导出。")
        }
        if let target, ![OutputFormat.txt, .md].contains(target),
           !(try document.nodes(forXPath: "//*[local-name()='drawing' or local-name()='pict']")).isEmpty {
            throw KumquatError.processFailed("当前 Word 转换尚不能保留内嵌图片，已停止以避免生成缺图的\(target.title)。可提取 TXT/Markdown 正文，或先在 Word 编辑器中导出。")
        }
        var styles: [String: XMLElement] = [:]
        if let data = contents["word/styles.xml"] {
            for case let style as XMLElement in try xml(data).nodes(forXPath: "//*[local-name()='style']") {
                if let id = attribute(style, "styleId") { styles[id] = style }
            }
        }
        var numbering: [String: [Int: (String, String, Int)]] = [:]
        var unsupportedNumbering: Set<String> = []
        if let data = contents["word/numbering.xml"] {
            let numberingDoc = try xml(data)
            var abstract: [String: [Int: (String, String, Int)]] = [:]
            var unsupportedAbstract: Set<String> = []
            for case let definition as XMLElement in try numberingDoc.nodes(forXPath: "//*[local-name()='abstractNum']") {
                let abstractID = attribute(definition, "abstractNumId") ?? ""
                var levels: [Int: (String, String, Int)] = [:]
                for level in children(definition, "lvl") {
                    let index = Int(attribute(level, "ilvl") ?? "0") ?? 0
                    levels[index] = (value(level, "numFmt") ?? "bullet", value(level, "lvlText") ?? "•", Int(value(level, "start") ?? "1") ?? 1)
                }
                abstract[abstractID] = levels
                let simple = levels[0].map { format, text, _ in
                    (format == "decimal" && text == "%1.") ||
                    (format == "bullet" && ["•", "\u{F0B7}"].contains(text))
                } ?? false
                let kind = value(definition, "multiLevelType")
                if children(definition, "lvl").count != 1 || !simple ||
                    (kind != nil && kind != "singleLevel") {
                    unsupportedAbstract.insert(abstractID)
                }
            }
            for case let num as XMLElement in try numberingDoc.nodes(forXPath: "//*[local-name()='num']") {
                let numID = attribute(num, "numId") ?? ""
                let abstractID = value(num, "abstractNumId") ?? ""
                numbering[numID] = abstract[abstractID]
                if unsupportedAbstract.contains(abstractID) || !children(num, "lvlOverride").isEmpty {
                    unsupportedNumbering.insert(numID)
                }
            }
        }
        func properties(_ id: String?, _ kind: String, seen: Set<String> = []) -> [String: XMLElement] {
            guard let id, !seen.contains(id), let style = styles[id] else { return [:] }
            var result = properties(value(style, "basedOn"), kind, seen: seen.union([id]))
            if let block = child(style, kind) {
                for case let property as XMLElement in block.children ?? [] { result[local(property)] = property }
            }
            return result
        }
        var counters: [String: Int] = [:]
        for case let paragraph as XMLElement in try document.nodes(forXPath: "//*[local-name()='p']") {
            let pPr = child(paragraph, "pPr") ?? XMLElement(name: "w:pPr")
            if pPr.parent == nil { paragraph.insertChild(pPr, at: 0) }
            let id = value(pPr, "pStyle")
            merge(properties(id, "pPr"), into: pPr)
            let runProperties = properties(id, "rPr")
            for case let run as XMLElement in try paragraph.nodes(forXPath: ".//*[local-name()='r']") {
                let rPr = child(run, "rPr") ?? XMLElement(name: "w:rPr")
                if rPr.parent == nil { run.insertChild(rPr, at: 0) }
                var inherited = runProperties
                inherited.merge(properties(value(rPr, "rStyle"), "rPr")) { _, character in character }
                merge(inherited, into: rPr)
            }
            if let numPr = child(pPr, "numPr"), let numID = value(numPr, "numId"), numID != "0" {
                guard let level = Int(value(numPr, "ilvl") ?? "0"), level == 0,
                      !unsupportedNumbering.contains(numID), numbering[numID]?[level] != nil else {
                    throw KumquatError.processFailed("当前 Word 转换尚不能保留复杂列表编号，已停止以避免改变编号内容。请先在支持完整 Word 排版的编辑器中导出。")
                }
                if let definition = numbering[numID]?[level] {
                    let key = numID + ":" + String(level)
                    let ordinal = counters[key] ?? definition.2
                    counters[key] = ordinal + 1
                    let marker: String
                    if definition.0 == "bullet" { marker = "• " }
                    else { marker = "\(ordinal). " }
                    let run = XMLElement(name: "w:r")
                    let text = XMLElement(name: "w:t", stringValue: marker)
                    text.addAttribute(XMLNode.attribute(withName: "xml:space", stringValue: "preserve") as! XMLNode)
                    run.addChild(text)
                    paragraph.insertChild(run, at: min(1, paragraph.childCount))
                    // Explicit glyphs are portable in TextKit PDFs and text-only
                    // targets; avoid the importer drawing the marker twice.
                    numPr.detach()
                    child(pPr, "pStyle")?.detach()
                }
            }
        }
        var zip = ZipWriter()
        for (name, data) in files {
            zip.add(name, data: name == "word/document.xml" ? document.xmlData(options: []) : data)
        }
        return zip.finish()
    }

    static func unsupportedTextFeatures(_ contents: [String: Data], document: XMLDocument) -> [String] {
        var features: [String] = []
        for (prefix, title) in [("word/header", "页眉"), ("word/footer", "页脚"), ("word/footnotes", "脚注"), ("word/endnotes", "尾注")] {
            if contents.contains(where: { name, data in
                guard name.hasPrefix(prefix), name.hasSuffix(".xml"), let doc = try? xml(data) else { return false }
                let hasText = ((try? doc.nodes(forXPath: "//*[local-name()='t']")) ?? []).contains { !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                let hasObjects = !((try? doc.nodes(forXPath: "//*[local-name()='drawing' or local-name()='pict' or local-name()='object' or local-name()='oMath' or local-name()='oMathPara' or local-name()='altChunk']")) ?? []).isEmpty
                return hasText || hasObjects
            }) { features.append(title) }
        }
        if !((try? document.nodes(forXPath: "//*[local-name()='oMath' or local-name()='oMathPara']")) ?? []).isEmpty { features.append("公式") }
        return features
    }

    static func xml(_ data: Data) throws -> XMLDocument {
        guard let source = String(data: data, encoding: .utf8), !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !source.localizedCaseInsensitiveContains("<!ENTITY") else { throw KumquatError.decodeFailed("Word XML") }
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }
    static func local(_ node: XMLNode) -> String { node.localName ?? node.name?.split(separator: ":").last.map(String.init) ?? "" }
    static func children(_ parent: XMLElement, _ name: String) -> [XMLElement] {
        (parent.children ?? []).compactMap { $0 as? XMLElement }.filter { local($0) == name }
    }
    static func child(_ parent: XMLElement, _ name: String) -> XMLElement? { children(parent, name).first }
    static func attribute(_ node: XMLElement, _ name: String) -> String? { node.attributes?.first { local($0) == name }?.stringValue }
    static func value(_ parent: XMLElement, _ name: String) -> String? { child(parent, name).flatMap { attribute($0, "val") } }
    static func merge(_ inherited: [String: XMLElement], into target: XMLElement) {
        for (name, property) in inherited where child(target, name) == nil {
            target.addChild(property.copy() as! XMLNode)
        }
    }
}

import Combine
import Foundation

/// Local, bounded history of saved results. The files themselves are never moved or removed.
struct SavedOutput: Codable, Identifiable, Sendable {
    var path: String
    var savedAt: Date
    var isDirectory = false
    var fileCount: Int?
    var imageCount: Int?
    var countIsLimited = false
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    static func inspect(_ record: SavedOutput) -> SavedOutput {
        var result = record
        // A failed refresh must never preserve an old, apparently exact count.
        result.fileCount = nil
        result.imageCount = nil
        result.countIsLimited = false
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard let values = try? record.url.resourceValues(forKeys: keys),
              let isDirectory = values.isDirectory else { return result }
        result.isDirectory = isDirectory
        guard result.isDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(at: record.url,
                  includingPropertiesForKeys: Array(keys),
                  options: []) else { return result }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp", "avif"]
        var files = 0, images = 0, inspected = 0
        // Conversion folders are usually small. Bound work for large archive extractions.
        // Do not use skipsHiddenFiles: cloud providers can transiently mark published
        // conversion pages hidden, which must not make a 26-page folder count as 3.
        for child in contents where !child.lastPathComponent.hasPrefix(".") {
            if inspected == 10_000 { result.countIsLimited = true; break }
            inspected += 1
            guard let childValues = try? child.resourceValues(forKeys: [.isRegularFileKey]),
                  let isRegularFile = childValues.isRegularFile else { return result }
            if isRegularFile {
                files += 1
                if imageExtensions.contains(child.pathExtension.lowercased()) { images += 1 }
            }
        }
        result.fileCount = files
        result.imageCount = images
        return result
    }
}

@MainActor
final class OutputHistory: ObservableObject {
    static let shared = OutputHistory()
    @Published private(set) var entries: [SavedOutput]
    private let defaults: UserDefaults
    private let key = "fileorbit.savedOutputs.v1"
    private let limit = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoded = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedOutput].self, from: $0) } ?? []
        var seen = Set<String>()
        entries = Array(decoded.filter { $0.path.hasPrefix("/") && seen.insert($0.path).inserted }.prefix(limit)).map {
            var entry = $0
            entry.fileCount = nil
            entry.imageCount = nil
            entry.countIsLimited = false
            return entry
        }
        refresh(entries)
    }

    func record(_ urls: [URL]) {
        let now = Date()
        var seen = Set<String>()
        let newEntries = urls.filter(\.isFileURL).compactMap { url -> SavedOutput? in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted ? SavedOutput(path: path, savedAt: now) : nil
        }
        guard !newEntries.isEmpty else { return }
        entries = Array((newEntries + entries.filter { !seen.contains($0.path) }).prefix(limit))
        persist()
        refresh(Array(newEntries.prefix(limit)))
    }

    private func refresh(_ pending: [SavedOutput]) {
        guard !pending.isEmpty else { return }
        Task {
            let inspected = await Task.detached(priority: .utility) { pending.map(SavedOutput.inspect) }.value
            for entry in inspected {
                if let index = self.entries.firstIndex(where: { $0.path == entry.path && $0.savedAt == entry.savedAt }) {
                    self.entries[index] = entry
                }
            }
            self.persist()
        }
    }

    func entry(for url: URL) -> SavedOutput? {
        entries.first { $0.path == url.standardizedFileURL.path }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

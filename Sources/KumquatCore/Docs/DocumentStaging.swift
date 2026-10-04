import Foundation
import Darwin

/// A result folder becomes visible under its final name only when every output succeeds.
/// On failure retain the isolated incomplete folder for inspection, never a misleading partial result.
enum DocumentStaging {
    static func writeDirectory(to destination: URL, body: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        // Do not rename a dot-prefixed staging folder into the user's result. On a synced
        // Desktop its hidden state can survive the rename, including on generated children.
        let container = try OutputNaming.temporaryDirectory(near: destination)
        defer { container.path.withCString { _ = rmdir($0) } } // Only removes an empty container.
        let pending = container.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try body(pending)
            return try OutputNaming.moveIntoPlace(pending, destination: destination)
        } catch let error as PartialOutputError {
            throw error
        } catch is CancellationError {
            throw KumquatError.processFailed("操作已取消。未完成文件保留在：\(pending.path)")
        } catch {
            throw KumquatError.processFailed("\(error.localizedDescription)\n未完成文件保留在：\(pending.path)")
        }
    }
}

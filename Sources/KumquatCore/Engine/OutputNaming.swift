import Foundation
import Darwin

/// Results are saved next to the original, Finder-style: "Photo.png", "Photo 2.png", "Photo Cropped.jpg".
public enum OutputNaming {
    public static func baseName(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// "Page 001.pdf" → "Page 001.jpg"
    public static func convertedURL(for input: URL, ext: String) -> URL {
        input.deletingLastPathComponent()
            .appendingPathComponent(baseName(of: input))
            .appendingPathExtension(ext)
    }

    /// "Page 001.jpg" + "Cropped" → "Page 001 Cropped.jpg"
    public static func taggedURL(for input: URL, tag: String, ext: String? = nil) -> URL {
        let ext = ext ?? input.pathExtension
        let name = "\(baseName(of: input)) \(tag)"
        let url = input.deletingLastPathComponent().appendingPathComponent(name)
        return ext.isEmpty ? url : url.appendingPathExtension(ext)
    }

    /// First free name of the form "Name.ext", "Name 2.ext", "Name 3.ext", ...
    public static func uniqueURL(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Writes into a system replacement location on the destination volume, then moves the finished
    /// file into place, so a half-written file never shows up next to the original.
    /// Returns the final (unique) URL.
    @discardableResult
    public static func write(to destination: URL, _ body: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let tempDir = try temporaryDirectory(near: destination)
        defer { tempDir.path.withCString { _ = rmdir($0) } }
        let temp = tempDir.appendingPathComponent(destination.lastPathComponent)
        try body(temp)
        guard fm.fileExists(atPath: temp.path) else {
            throw KumquatError.encodeFailed(destination.lastPathComponent)
        }
        return try moveIntoPlace(temp, destination: destination)
    }

    /// Async variant of `write(to:_:)`.
    @discardableResult
    public static func write(to destination: URL, _ body: (URL) async throws -> Void) async throws -> URL {
        let fm = FileManager.default
        let tempDir = try temporaryDirectory(near: destination)
        defer { tempDir.path.withCString { _ = rmdir($0) } }
        let temp = tempDir.appendingPathComponent(destination.lastPathComponent)
        try await body(temp)
        guard fm.fileExists(atPath: temp.path) else {
            throw KumquatError.encodeFailed(destination.lastPathComponent)
        }
        return try moveIntoPlace(temp, destination: destination)
    }

    /// Creates a uniquely named folder next to `destination` and returns it.
    public static func makeDirectory(_ destination: URL) throws -> URL {
        let url = uniqueURL(destination)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func temporaryDirectory(near destination: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                    appropriateFor: destination, create: true)
    }

    static func moveIntoPlace(_ temp: URL, destination: URL) throws -> URL {
        let fm = FileManager.default
        try makeOutputVisible(temp)
        // Retry on the off chance another process grabs the name between the check and the move.
        for _ in 0..<5 {
            let final = uniqueURL(destination)
            do {
                try fm.moveItem(at: temp, to: final)
                do { try makeOutputVisible(final) }
                catch { throw PartialOutputError(outputs: [final], underlyingError: error) }
                return final
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw KumquatError.encodeFailed(destination.lastPathComponent)
    }

    /// Only touches newly generated outputs, retaining unrelated flags and Finder metadata.
    /// Dotfiles and symlinks within archives retain their original visibility and targets.
    static func makeOutputVisible(_ root: URL) throws {
        func clearHidden(_ url: URL) throws -> Bool {
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if (info.st_mode & S_IFMT) == S_IFLNK { return false }
            if (info.st_flags & UInt32(UF_HIDDEN)) != 0 {
                guard url.path.withCString({ chflags($0, info.st_flags & ~UInt32(UF_HIDDEN)) }) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            var finderInfo = [UInt8](repeating: 0, count: 32)
            let read = url.path.withCString { path in
                finderInfo.withUnsafeMutableBytes { getxattr(path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            }
            if read < 0 && errno != ENOATTR && errno != ENOTSUP {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if read == 32 && finderInfo[8] & 0x40 != 0 {
                finderInfo[8] &= ~0x40 // kIsInvisible; retain all other FinderInfo bits.
                let written = url.path.withCString { path in
                    finderInfo.withUnsafeBytes { setxattr(path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
                }
                guard written == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            return (info.st_mode & S_IFMT) == S_IFDIR
        }
        guard try clearHidden(root) else { return }
        var directories = [root]
        while let directory = directories.popLast() {
            for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if child.lastPathComponent.hasPrefix(".") { continue }
                if try clearHidden(child) { directories.append(child) }
            }
        }
    }
}

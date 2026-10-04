import Darwin
import Foundation

/// Bounded archive processing with the system libarchive. No archive-controlled pathname is ever
/// passed to an extraction program; only regular files and directories are materialized.
public enum ArchiveConverter {
    public struct Limits: Sendable {
        public var maximumEntries = 10_000
        public var maximumFileBytes: Int64 = 512 * 1024 * 1024
        public var maximumTotalBytes: Int64 = 1024 * 1024 * 1024
        public var maximumExpansionRatio: Double = 200
        public var expansionAllowanceBytes: Int64 = 16 * 1024 * 1024
        public init() {}
    }

    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "gzip", "tgz", "rar"]

    /// Archives a regular file/directory, or transcodes supported archives without writing their
    /// contents to disk. GZIP is a single-file stream: multi-file inputs produce a .tar.gz.
    public static func convert(_ input: URL, to format: OutputFormat) async throws -> [URL] {
        guard [OutputFormat.zip, .tar, .gz].contains(format) else {
            throw KumquatError.unsupportedConversion(from: "archive", to: format.title)
        }
        try Task.checkCancellation()
        let info = try input.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard info.isSymbolicLink != true else { throw unsafe("不打包符号链接") }
        let isArchive = info.isDirectory != true && archiveExtensions.contains(input.pathExtension.lowercased())
        let gzipTar = format == .gz && (info.isDirectory == true || isArchive)
        let ext = gzipTar ? "tar.gz" : format.fileExtension
        let destination = format == .gz && !gzipTar
            ? input.appendingPathExtension("gz")
            : OutputNaming.convertedURL(for: input, ext: ext)
        let result = try OutputNaming.write(to: destination) { output in
            let library = try ArchiveLibrary()
            let writer = try Writer(library: library, output: output, format: format, gzipTar: gzipTar)
            defer { writer.free() }
            if isArchive {
                let reader = try Reader(input: input, library: library, limits: Limits())
                defer { reader.free() }
                while let entry = try reader.next() {
                    if reader.isRaw {
                        // Raw GZIP has no size header, while TAR requires one. The same per-file
                        // and expansion bounds remain enforced before each buffer append.
                        var content = Data()
                        while let bytes = try reader.chunk() { content.append(bytes) }
                        try writer.start(name: entry.name, directory: false, size: Int64(content.count))
                        try writer.data(content)
                    } else {
                        try writer.start(name: entry.name, directory: entry.directory, size: entry.size)
                        if !entry.directory {
                            while let data = try reader.chunk() { try writer.data(data) }
                        }
                    }
                }
            } else {
                try appendFilesystem(input, name: input.lastPathComponent, writer: writer, limits: Limits())
            }
            try writer.close()
        }
        return [result]
    }

    public static func extract(_ input: URL) async throws -> [URL] {
        try extract(input, limits: Limits())
    }

    /// Exposed for conservative limits in embeddings and regression tests.
    public static func extract(_ input: URL, limits: Limits) throws -> [URL] {
        guard archiveExtensions.contains(input.pathExtension.lowercased()) else {
            throw KumquatError.unsupportedInput(input.lastPathComponent)
        }
        let library = try ArchiveLibrary()
        let reader = try Reader(input: input, library: library, limits: limits)
        defer { reader.free() }
        let destination = input.deletingLastPathComponent().appendingPathComponent("\(OutputNaming.baseName(of: input)) Extracted")
        let folder = try DocumentStaging.writeDirectory(to: destination) { staging in
            while let entry = try reader.next() {
                try Task.checkCancellation()
                let target = staging.appendingPathComponent(entry.name)
                try createParents(of: target, inside: staging)
                if entry.directory {
                    var directory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: target.path, isDirectory: &directory) {
                        guard directory.boolValue, try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                            throw unsafe("目录与其他条目冲突：\(entry.name)")
                        }
                    } else {
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])
                    }
                } else {
                    // Exclusive creation also catches duplicate paths, case/Unicode collisions and
                    // symlink replacement. Permissions never inherit executable or setuid bits.
                    let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                    guard fd >= 0 else { throw unsafe("不能安全创建或条目重名：\(entry.name)") }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    while let data = try reader.chunk() { try handle.write(contentsOf: data) }
                }
            }
        }
        return [folder]
    }

    /// Reject absolute paths, Windows drive/UNC paths, traversal, control characters and ambiguous
    /// separators before touching the filesystem. Normalize benign './' prefixes used by tar.
    static func safePath(_ pathname: String) throws -> String {
        guard !pathname.isEmpty, pathname.utf8.count <= 4096,
              !pathname.hasPrefix("/"), !pathname.contains("\\"), !pathname.contains(":"),
              !pathname.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw unsafe("不安全的归档路径：\(pathname.prefix(100))")
        }
        let parts = pathname.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count <= 128 else { throw unsafe("归档目录层级超过 128 层限制") }
        guard !parts.contains("..") else { throw unsafe("归档包含父级路径") }
        let normalized = parts.filter { $0 != "." }.joined(separator: "/")
        guard !normalized.isEmpty else { throw unsafe("归档包含空路径") }
        return normalized
    }

    static func createParents(of target: URL, inside root: URL) throws {
        let relative = target.deletingLastPathComponent().path.dropFirst(root.path.count)
        var parent = root
        for component in relative.split(separator: "/") {
            parent.appendPathComponent(String(component))
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory) {
                guard directory.boolValue, try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw unsafe("归档目录包含链接或文件冲突")
                }
            } else {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }
    }

    static func appendFilesystem(_ input: URL, name: String, writer: Writer, limits: Limits) throws {
        var entries = 0, total: Int64 = 0
        func append(_ url: URL, _ name: String) throws {
            try Task.checkCancellation()
            entries += 1
            guard entries <= limits.maximumEntries else { throw unsafe("条目数超过限制") }
            let resource = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard resource.isSymbolicLink != true else { throw unsafe("不打包符号链接：\(name)") }
            if resource.isDirectory == true {
                try writer.start(name: safePath(name), directory: true, size: 0)
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try append(child, name + "/" + child.lastPathComponent) }
            } else {
                guard resource.isRegularFile == true else { throw unsafe("只支持普通文件和目录") }
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw unsafe("不能安全打开：\(name)") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var status = stat()
                guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw unsafe("文件类型已变化") }
                let size = Int64(status.st_size)
                guard size >= 0, size <= limits.maximumFileBytes, total <= limits.maximumTotalBytes - size else {
                    throw unsafe("打包大小超过单文件 512 MiB 或总量 1 GiB 限制")
                }
                total += size
                try writer.start(name: safePath(name), directory: false, size: size)
                var read: Int64 = 0
                while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
                    try Task.checkCancellation()
                    read += Int64(bytes.count)
                    guard read <= size else { throw unsafe("读取时文件变大：\(name)") }
                    try writer.data(bytes)
                }
                guard read == size else { throw unsafe("读取时文件大小变化：\(name)") }
            }
        }
        try append(input, name)
    }

    static func unsafe(_ reason: String) -> KumquatError { .processFailed("安全检查停止压缩包处理：\(reason)。") }

    struct Entry { let name: String; let directory: Bool; let size: Int64 }

    final class Reader {
        let lib: ArchiveLibrary, archive: OpaquePointer, input: URL, limits: Limits
        let expandedLimit: Int64
        var entries = 0
        var total: Int64 = 0
        var currentBytes: Int64 = 0
        var currentDeclared: Int64 = 0
        var paths: [String: Bool] = [:] // canonical path -> is directory, including implicit parents
        var released = false
        var isRaw: Bool { lib.format(archive) == 0x90000 }

        init(input: URL, library: ArchiveLibrary, limits: Limits) throws {
            self.lib = library; self.input = input; self.limits = limits
            guard limits.maximumEntries > 0, limits.maximumFileBytes > 0, limits.maximumTotalBytes > 0,
                  limits.maximumExpansionRatio.isFinite, limits.maximumExpansionRatio > 0, limits.expansionAllowanceBytes >= 0 else {
                throw unsafe("无效的解压限制")
            }
            let info = try input.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw unsafe("归档必须为普通文件") }
            let compressed = Double(info.fileSize ?? 0)
            expandedLimit = Int64(min(Double(limits.maximumTotalBytes), max(Double(limits.expansionAllowanceBytes), compressed * limits.maximumExpansionRatio)))
            guard let a = library.readNew() else { throw unsafe("不能初始化系统解压引擎") }
            archive = a
            do {
                try check(library.readSupportFilterAll(a))
                try check(library.readSupportFormatAll(a))
                if ["gz", "gzip"].contains(input.pathExtension.lowercased()) {
                    let handle = try FileHandle(forReadingFrom: input)
                    defer { try? handle.close() }
                    guard try handle.read(upToCount: 2) == Data([0x1f, 0x8b]) else { throw unsafe("GZIP 文件头无效") }
                    try check(library.readSupportFormatRaw(a))
                }
                try check(input.path.withCString { library.readOpenFilename(a, $0, 64 * 1024) })
            } catch { _ = library.readFree(a); released = true; throw error }
        }
        deinit { free() }
        func free() { if !released { _ = lib.readFree(archive); released = true } }
        func check(_ status: Int32) throws {
            guard status >= 0 else { throw unsafe(lib.message(archive)) }
        }
        func next() throws -> Entry? {
            while true {
                try Task.checkCancellation()
                var pointer: OpaquePointer?
                let status = lib.readNextHeader(archive, &pointer)
                if status == 1 { return nil }
                try check(status)
                guard let entry = pointer, let path = lib.entryPathname(entry) else { throw unsafe("归档条目没有文件名") }
                entries += 1
                guard entries <= limits.maximumEntries else { throw unsafe("条目数超过 \(limits.maximumEntries) 限制") }
                guard lib.entrySymlink(entry) == nil, lib.entryHardlink(entry) == nil else { throw unsafe("归档含符号链接或硬链接") }
                let type = lib.entryFiletype(entry)
                guard type == 0o100000 || type == 0o040000 else { throw unsafe("归档包含设备、管道或其他特殊文件") }
                let size = lib.entrySize(entry)
                guard type != 0o040000 || size == 0 else { throw unsafe("目录条目包含数据") }
                guard size >= 0, size <= limits.maximumFileBytes, total <= expandedLimit - size else {
                    throw unsafe("解压大小或压缩比超过限制")
                }
                currentBytes = 0; currentDeclared = size
                var name = String(cString: path)
                // Raw GZIP has no portable pathname; do not trust a stored original name.
                if lib.format(archive) == 0x90000 { name = input.deletingPathExtension().lastPathComponent }
                // A conventional tar root entry is harmless and should not stop the archive.
                if type == 0o040000 && (name == "." || name == "./") { continue }
                let safe = try safePath(name)
                let components = safe.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
                var key = ""
                for (index, component) in components.enumerated() {
                    key += (key.isEmpty ? "" : "/") + component
                    let directory = index < components.count - 1 || type == 0o040000
                    if let existing = paths[key], !existing || !directory { throw unsafe("归档路径重名或目录冲突：\(safe)") }
                    paths[key] = directory
                }
                return Entry(name: safe, directory: type == 0o040000, size: size)
            }
        }
        func chunk() throws -> Data? {
            try Task.checkCancellation()
            var data = Data(count: 64 * 1024)
            let n = data.withUnsafeMutableBytes { lib.readData(archive, $0.baseAddress!, $0.count) }
            guard n >= 0 else { throw unsafe(lib.message(archive)) }
            if n == 0 {
                // Raw streams don't carry an uncompressed size. Other formats must agree.
                if lib.format(archive) != 0x90000 && currentBytes != currentDeclared { throw unsafe("解压长度与条目声明不符") }
                return nil
            }
            currentBytes += Int64(n); total += Int64(n)
            guard currentBytes <= limits.maximumFileBytes, total <= expandedLimit else {
                throw unsafe("解压大小或压缩比超过限制")
            }
            data.count = n
            return data
        }
    }

    final class Writer {
        let lib: ArchiveLibrary, archive: OpaquePointer
        var released = false
        init(library: ArchiveLibrary, output: URL, format: OutputFormat, gzipTar: Bool) throws {
            lib = library
            guard let a = library.writeNew() else { throw unsafe("不能初始化系统压缩引擎") }
            archive = a
            do {
                if format == .zip {
                    try check(lib.writeSetFormatZip(a))
                    // Explicit charset also sets ZIP's UTF-8 flag. Without it libarchive can
                    // write UTF-8 bytes marked as CP437, corrupting names in other readers.
                    try check(lib.writeSetFormatOption(a, "zip", "hdrcharset", "UTF-8"))
                }
                else if format == .gz && !gzipTar { try check(lib.writeSetFormatRaw(a)) }
                else { try check(lib.writeSetFormatPax(a)) }
                if format == .gz { try check(lib.writeAddFilterGzip(a)) }
                try check(output.path.withCString { lib.writeOpenFilename(a, $0) })
            } catch { _ = lib.writeFree(a); released = true; throw error }
        }
        deinit { free() }
        func free() { if !released { _ = lib.writeFree(archive); released = true } }
        func check(_ status: Int32) throws { guard status >= 0 else { throw unsafe(lib.message(archive)) } }
        func start(name: String, directory: Bool, size: Int64) throws {
            try Task.checkCancellation()
            guard let entry = lib.entryNew() else { throw unsafe("无法创建归档条目") }
            defer { lib.entryFree(entry) }
            name.withCString { lib.entrySetPathname(entry, $0) }
            lib.entrySetFiletype(entry, directory ? 0o040000 : 0o100000)
            lib.entrySetPerm(entry, directory ? 0o700 : 0o600)
            lib.entrySetSize(entry, size)
            try check(lib.writeHeader(archive, entry))
        }
        func data(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { lib.writeData(archive, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                guard written > 0 else { throw unsafe(lib.message(archive)) }
                offset += written
            }
        }
        func close() throws { try check(lib.writeClose(archive)) }
    }
}

/// Stable C entry points from macOS's built-in libarchive, loaded without third-party packages.
/// Keep the library handle alive until all reader/writer objects have released their C resources.
final class ArchiveLibrary {
    typealias New = @convention(c) () -> OpaquePointer?
    typealias One = @convention(c) (OpaquePointer) -> Int32
    typealias FreeEntry = @convention(c) (OpaquePointer) -> Void
    typealias Name = @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?
    typealias OpenRead = @convention(c) (OpaquePointer, UnsafePointer<CChar>, Int) -> Int32
    typealias OpenWrite = @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Int32
    typealias Next = @convention(c) (OpaquePointer, UnsafeMutablePointer<OpaquePointer?>) -> Int32
    typealias DataRead = @convention(c) (OpaquePointer, UnsafeMutableRawPointer, Int) -> Int
    typealias DataWrite = @convention(c) (OpaquePointer, UnsafeRawPointer, Int) -> Int
    typealias EntryType = @convention(c) (OpaquePointer) -> UInt32
    typealias Size = @convention(c) (OpaquePointer) -> Int64
    typealias SetName = @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Void
    typealias SetUInt = @convention(c) (OpaquePointer, UInt32) -> Void
    typealias SetSize = @convention(c) (OpaquePointer, Int64) -> Void
    typealias Header = @convention(c) (OpaquePointer, OpaquePointer) -> Int32
    typealias FormatOption = @convention(c) (OpaquePointer, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    let handle: UnsafeMutableRawPointer
    let readNew: New, writeNew: New, entryNew: New
    let readSupportFilterAll: One, readSupportFormatAll: One, readSupportFormatRaw: One
    let readFree: One, writeFree: One, writeClose: One, format: One
    let writeSetFormatZip: One, writeSetFormatPax: One, writeSetFormatRaw: One, writeAddFilterGzip: One
    let readOpenFilename: OpenRead, writeOpenFilename: OpenWrite, readNextHeader: Next
    let readData: DataRead, writeData: DataWrite
    let entryPathname: Name, entrySymlink: Name, entryHardlink: Name, errorString: Name
    let entryFiletype: EntryType, entrySize: Size, entryFree: FreeEntry
    let entrySetPathname: SetName, entrySetFiletype: SetUInt, entrySetPerm: SetUInt, entrySetSize: SetSize
    let writeHeader: Header
    let writeSetFormatOption: FormatOption

    init() throws {
        guard let library = dlopen("/usr/lib/libarchive.2.dylib", RTLD_LOCAL | RTLD_NOW) else {
            throw KumquatError.processFailed("此 macOS 系统未提供可用的 libarchive。")
        }
        handle = library
        func load<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(library, name) else {
                throw KumquatError.processFailed("系统归档引擎缺少 \(name)。")
            }
            return unsafeBitCast(address, to: type)
        }
        do {
            readNew = try load("archive_read_new", as: New.self)
            writeNew = try load("archive_write_new", as: New.self)
            entryNew = try load("archive_entry_new", as: New.self)
            readSupportFilterAll = try load("archive_read_support_filter_all", as: One.self)
            readSupportFormatAll = try load("archive_read_support_format_all", as: One.self)
            readSupportFormatRaw = try load("archive_read_support_format_raw", as: One.self)
            readFree = try load("archive_read_free", as: One.self)
            writeFree = try load("archive_write_free", as: One.self)
            writeClose = try load("archive_write_close", as: One.self)
            format = try load("archive_format", as: One.self)
            writeSetFormatZip = try load("archive_write_set_format_zip", as: One.self)
            writeSetFormatPax = try load("archive_write_set_format_pax_restricted", as: One.self)
            writeSetFormatRaw = try load("archive_write_set_format_raw", as: One.self)
            writeAddFilterGzip = try load("archive_write_add_filter_gzip", as: One.self)
            readOpenFilename = try load("archive_read_open_filename", as: OpenRead.self)
            writeOpenFilename = try load("archive_write_open_filename", as: OpenWrite.self)
            readNextHeader = try load("archive_read_next_header", as: Next.self)
            readData = try load("archive_read_data", as: DataRead.self)
            writeData = try load("archive_write_data", as: DataWrite.self)
            entryPathname = try load("archive_entry_pathname_utf8", as: Name.self)
            entrySymlink = try load("archive_entry_symlink", as: Name.self)
            entryHardlink = try load("archive_entry_hardlink", as: Name.self)
            errorString = try load("archive_error_string", as: Name.self)
            entryFiletype = try load("archive_entry_filetype", as: EntryType.self)
            entrySize = try load("archive_entry_size", as: Size.self)
            entryFree = try load("archive_entry_free", as: FreeEntry.self)
            entrySetPathname = try load("archive_entry_set_pathname_utf8", as: SetName.self)
            entrySetFiletype = try load("archive_entry_set_filetype", as: SetUInt.self)
            entrySetPerm = try load("archive_entry_set_perm", as: SetUInt.self)
            entrySetSize = try load("archive_entry_set_size", as: SetSize.self)
            writeHeader = try load("archive_write_header", as: Header.self)
            writeSetFormatOption = try load("archive_write_set_format_option", as: FormatOption.self)
        } catch { dlclose(library); throw error }
    }
    deinit { dlclose(handle) }
    func message(_ archive: OpaquePointer) -> String { errorString(archive).map { String(cString: $0) } ?? "系统归档引擎处理失败" }
}

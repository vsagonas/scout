import Compression
import Foundation

/// A small ZIP writer (DEFLATE through the Compression framework). The sandboxed edition cannot run `ditto`,
/// so it makes archives itself. Single volume, no ZIP64: files up to 4 GB, 65,535 entries.
enum ZipWriter {
    enum ZipError: LocalizedError {
        case tooBig(String)
        case tooManyFiles
        case archiveTooBig
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .tooBig(let n): String(localized: "\(n) is too big for a ZIP file (4 GB limit)")
            case .tooManyFiles: String(localized: "This selection is too big for a ZIP file (4 GB limit)")
            case .archiveTooBig: String(localized: "The archive is too big for a ZIP file (4 GB limit)")
            case .unreadable(let n): String(localized: "Couldn't read \(n)")
            }
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { raw in
            for byte in raw { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    private struct Entry {
        var name: String
        var crc: UInt32
        var compressed: UInt32
        var size: UInt32
        var method: UInt16
        var offset: UInt32
        var dosTime: UInt16
        var dosDate: UInt16
        var isDirectory: Bool
    }

    private static func dos(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        return (UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2)),
                UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1)))
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

    /// Writes `destination` with the given files and folders (folders are included with everything inside).
    /// `rootName` puts everything under one folder inside the archive (like `ditto --keepParent` for a set of files).
    static func write(_ sources: [URL], to destination: URL, rootName: String? = nil) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var entries: [Entry] = []
        var offset: UInt64 = 0

        func put(_ data: Data) throws {
            try out.write(contentsOf: data)
            offset += UInt64(data.count)
        }

        func add(_ file: URL, as name: String, isDirectory: Bool) throws {
            guard offset < UInt64(UInt32.max) - 1 else { throw ZipError.tooBig(file.lastPathComponent) }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let stamp = dos(modified)
            let entryName = isDirectory ? name + "/" : name
            let nameData = Data(entryName.utf8)
            var crc: UInt32 = 0
            var payload = Data()
            var method: UInt16 = 0
            var uncompressed = 0
            if !isDirectory {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { throw ZipError.unreadable(file.lastPathComponent) }
                guard data.count < Int(UInt32.max) else { throw ZipError.tooBig(file.lastPathComponent) }
                crc = crc32(0, data)
                uncompressed = data.count
                payload = data
                // Deflate what is worth it (small and mid-size files); store the rest as is.
                if data.count > 0 && data.count <= 48 * 1024 * 1024 {
                    let capacity = data.count + data.count / 10 + 1024
                    var buffer = [UInt8](repeating: 0, count: capacity)
                    let written = data.withUnsafeBytes { src in
                        compression_encode_buffer(&buffer, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                    }
                    if written > 0 && written < data.count { payload = Data(buffer[0..<written]); method = 8 }
                }
            }
            let entry = Entry(name: entryName, crc: crc, compressed: UInt32(payload.count), size: UInt32(uncompressed),
                              method: method, offset: UInt32(offset), dosTime: stamp.time, dosDate: stamp.date, isDirectory: isDirectory)
            var header = Data()
            header += le32(0x04034B50) + le16(20) + le16(0x0800) + le16(method) + le16(stamp.time) + le16(stamp.date)
            header += le32(crc) + le32(entry.compressed) + le32(entry.size) + le16(UInt16(nameData.count)) + le16(0)
            try put(header + nameData)
            if !payload.isEmpty { try put(payload) }
            entries.append(entry)
        }

        func addTree(_ url: URL, prefix: String) throws {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let name = prefix.isEmpty ? url.lastPathComponent : prefix + "/" + url.lastPathComponent
            if values?.isDirectory == true {
                try add(url, as: name, isDirectory: true)
                let children = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { try addTree(child, prefix: name) }
            } else {
                try add(url, as: name, isDirectory: false)
            }
        }

        for source in sources { try addTree(source, prefix: rootName ?? "") }
        guard entries.count < 65535 else { throw ZipError.tooManyFiles }
        let centralStart = offset
        for e in entries {
            let nameData = Data(e.name.utf8)
            var record = Data()
            record += le32(0x02014B50) + le16(0x031E) + le16(20) + le16(0x0800) + le16(e.method) + le16(e.dosTime) + le16(e.dosDate)
            record += le32(e.crc) + le32(e.compressed) + le32(e.size) + le16(UInt16(nameData.count)) + le16(0) + le16(0) + le16(0) + le16(0)
            record += le32(e.isDirectory ? 0x41ED0010 : 0x81A40000) + le32(e.offset)
            try put(record + nameData)
        }
        let centralSize = offset - centralStart
        guard offset < UInt64(UInt32.max) else { throw ZipError.archiveTooBig }
        var end = Data()
        end += le32(0x06054B50) + le16(0) + le16(0) + le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        end += le32(UInt32(centralSize)) + le32(UInt32(centralStart)) + le16(0)
        try put(end)
    }

    /// Reads a ZIP back (central directory, inflate, CRC check). Returns the entry names, or nil when anything is off.
    /// Used by checks to prove an archive is valid without running an external tool.
    static func verify(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url), data.count > 22 else { return nil }
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        var end = b.count - 22
        while end >= 0, !(b[end] == 0x50 && b[end + 1] == 0x4B && b[end + 2] == 5 && b[end + 3] == 6) { end -= 1 }
        guard end >= 0 else { return nil }
        let count = u16(end + 10)
        var p = u32(end + 16)
        var names: [String] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014B50 else { return nil }
            let method = u16(p + 10), crc = u32(p + 16), csize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), offset = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            guard offset + 30 <= b.count, u32(offset) == 0x04034B50 else { return nil }
            let start = offset + 30 + u16(offset + 26) + u16(offset + 28)
            guard start + csize <= b.count else { return nil }
            if !name.hasSuffix("/") {
                var content = Data(b[start..<(start + csize)])
                if method == 8 {
                    var out = [UInt8](repeating: 0, count: max(size, 1))
                    let n = content.withUnsafeBytes { src in
                        compression_decode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, content.count, nil, COMPRESSION_ZLIB)
                    }
                    guard n == size else { return nil }
                    content = Data(out[0..<size])
                } else if method != 0 { return nil }
                guard content.count == size, Int(crc32(0, content)) == crc else { return nil }
            }
            names.append(name)
            p += 46 + nameLen + extraLen + commentLen
        }
        return names
    }
}

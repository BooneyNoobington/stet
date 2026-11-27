import Foundation

/// Looks into a ZIP before anything in it is unpacked: a backup to restore or a wiki to import
/// may come from someone else. Refused: absolute paths and `..` (they would land outside the
/// target folder), links (they could make Zadur read or show any file on this Mac, e.g. a wiki
/// entry that is really `~/.ssh/id_rsa`), devices, and encrypted entries (unzip would wait for
/// a password).
///
/// The names are read straight from the ZIP's central directory, which is what unzip extracts by.
public enum ZipCheck {
    public enum Problem: Error, LocalizedError, Equatable {
        case notAZip(URL)
        case unsafeEntry(URL, String)
        case encrypted(URL)

        public var errorDescription: String? {
            switch self {
            case .notAZip(let url): "„\(url.lastPathComponent)“ ist keine ZIP-Datei oder beschädigt."
            case .unsafeEntry(let url, let name): "„\(url.lastPathComponent)“ enthält „\(name)“, das außerhalb landen oder auf etwas anderes zeigen würde. Zadur packt die Datei deshalb nicht aus."
            case .encrypted(let url): "„\(url.lastPathComponent)“ ist mit einem Passwort verschlüsselt. Zadur kann sie nicht auspacken."
            }
        }
    }

    struct Entry: Equatable {
        var name: String
        /// Unix file mode, if the ZIP was made on a Unix system (macOS included).
        var mode: UInt32?
        var encrypted: Bool
    }

    /// Throws if anything in `zip` shouldn't be unpacked.
    public static func check(_ zip: URL) throws {
        for entry in try entries(of: zip) {
            let name = entry.name
            if name.isEmpty || name.hasPrefix("/") || name.contains("\\") || name.contains("\u{0}")
                || name.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                throw Problem.unsafeEntry(zip, name)
            }
            // Only files and folders.
            if let mode = entry.mode, ![0, 0o100000, 0o040000].contains(mode & 0o170000) {
                throw Problem.unsafeEntry(zip, name)
            }
            if entry.encrypted { throw Problem.encrypted(zip) }
        }
    }

    static func entries(of zip: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: zip)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // The end record is in the last 22 bytes plus a comment of at most 64 KB.
        let tailLength = min(size, 22 + 65_535)
        try handle.seek(toOffset: size - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count >= 22,
              let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x0605_4b50 })
        else { throw Problem.notAZip(zip) }

        var count = UInt64(tail.u16(end + 10))
        var directorySize = UInt64(tail.u32(end + 12))
        var directoryOffset = UInt64(tail.u32(end + 16))
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: the real numbers are in the ZIP64 end record, found through its locator.
            guard end >= 20, tail.u32(end - 20) == 0x0706_4b50 else { throw Problem.notAZip(zip) }
            try handle.seek(toOffset: tail.u64(end - 20 + 8))
            let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
            guard record.count == 56, record.u32(0) == 0x0606_4b50 else { throw Problem.notAZip(zip) }
            count = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
        }
        guard directoryOffset <= size, directorySize <= size - directoryOffset else { throw Problem.notAZip(zip) }

        try handle.seek(toOffset: directoryOffset)
        let directory = [UInt8](try handle.read(upToCount: Int(directorySize)) ?? Data())
        var entries: [Entry] = []
        var at = 0
        for _ in 0..<count {
            guard at + 46 <= directory.count, directory.u32(at) == 0x0201_4b50 else { throw Problem.notAZip(zip) }
            let madeOn = directory.u16(at + 4) >> 8
            let nameLength = Int(directory.u16(at + 28))
            let extraLength = Int(directory.u16(at + 30))
            let commentLength = Int(directory.u16(at + 32))
            guard at + 46 + nameLength <= directory.count else { throw Problem.notAZip(zip) }
            let nameBytes = directory[(at + 46)..<(at + 46 + nameLength)]
            entries.append(Entry(
                name: nameBytes.contains(0) ? "\u{0}" : String(decoding: nameBytes, as: UTF8.self),
                mode: madeOn == 3 || madeOn == 19 ? directory.u32(at + 38) >> 16 : nil,  // Unix, OS X
                encrypted: directory.u16(at + 8) & 1 != 0
            ))
            at += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }
}

private extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}

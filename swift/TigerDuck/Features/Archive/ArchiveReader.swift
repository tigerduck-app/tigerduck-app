#if os(iOS)
import CLibArchive
import Foundation

nonisolated enum ArchiveProblem: Error, Sendable, Hashable {
    case password, unsupported, tooLarge, tooMany, link, broken
}

nonisolated struct ArchiveItem: Sendable, Hashable, Identifiable {
    let index: Int
    let path: String
    let size: Int64?
    let modified: Date?
    let isDirectory: Bool
    let problem: ArchiveProblem?

    var id: Int { index }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

nonisolated struct ArchiveListing: Sendable {
    let items: [ArchiveItem]
    let truncated: Bool
}

/// The Android app's limits, so an archive opens, or fails, alike on both.
nonisolated struct ArchiveLimits: Sendable {
    var maxItems = 5_000
    var maxZipDirectoryBytes: Int64 = 16 << 20
    var maxEntryBytes: Int64 = 256 << 20
    var maxRatio: Int64 = 100
    var ratioFreeBytes: Int64 = 16 << 20
    var maxScanBytes: Int64 = 2 << 30
    var timeLimit: Duration = .seconds(60)
}

nonisolated enum ArchiveReader {
    static func list(_ archive: URL, limits: ArchiveLimits = ArchiveLimits()) throws -> ArchiveListing {
        try ArchivePass.run(archive, limits: limits) { pass in
            var items: [ArchiveItem] = []
            var index = 0
            while let entry = try pass.nextEntry(listing: true) {
                defer { index += 1 }
                guard let path = pass.path(of: entry) else { continue }
                if items.count == limits.maxItems { return ArchiveListing(items: items, truncated: true) }
                items.append(pass.item(entry, index: index, path: path))
            }
            return ArchiveListing(items: items, truncated: false)
        }
    }

    static func extract(
        _ item: ArchiveItem, from archive: URL, into folder: URL, limits: ArchiveLimits = ArchiveLimits()
    ) throws -> URL {
        if let problem = item.problem { throw problem }
        guard !item.isDirectory else { throw ArchiveProblem.unsupported }
        return try ArchivePass.run(archive, limits: limits) { pass in
            var index = 0
            while let entry = try pass.nextEntry() {
                defer { index += 1 }
                guard index == item.index else { continue }
                guard pass.path(of: entry) == item.path else { throw ArchiveProblem.broken }
                return try pass.writeData(to: folder, name: fileName(for: item.name))
            }
            throw ArchiveProblem.broken
        }
    }

    static func normalized(_ path: String) -> String? {
        let parts = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").filter { $0 != "." }
        guard !parts.contains("..") else { return nil }
        let joined = parts.joined(separator: "/")
        return joined.isEmpty ? nil : joined
    }

    static func fileName(for name: String) -> String {
        guard name.utf8.count > 255 else { return name }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty || ext.utf8.count > 16 ? "file" : "file.\(ext)"
    }
}

/// libarchive holds every record of a zip's central directory before the first entry. Like its
/// seekable zip reader, this finds the last end record in the file's final 16 KiB, wherever the
/// file starts, and measures the records libarchive would read from where it starts reading up
/// to that end record. A zip64 end record that passes libarchive's checks names that start
/// instead of the plain end record, whatever the plain one says.
nonisolated enum ArchiveZipDirectory {
    private static let searched = 16 << 10
    private static let endRecordSize = 22

    static func check(_ file: Int32, size: Int64, limit: Int64) throws {
        let tailSize = Int(min(size, Int64(searched)))
        let tailAt = size - Int64(tailSize)
        guard let tail = read(file, at: tailAt, count: tailSize),
              let at = stride(from: tailSize - endRecordSize, through: 0, by: -1)
                .first(where: { word(tail, $0, 4) == 0x0605_4B50 }) else { return }
        let endAt = tailAt + Int64(at)
        var span: Int64 = 0
        let directorySize = Int64(word(tail, at + 12, 4))
        if word(tail, at + 4, 2) == 0, word(tail, at + 6, 2) == 0, word(tail, at + 8, 2) == word(tail, at + 10, 2),
           Int64(word(tail, at + 16, 4)) + directorySize <= endAt {
            span = directorySize
        }
        if at >= 20, word(tail, at - 20, 4) == 0x0706_4B50, word(tail, at - 16, 4) == 0, word(tail, at - 4, 4) == 1 {
            let recordAt = Int64(bitPattern: word(tail, at - 12, 8))
            if let directoryAt = zip64DirectoryStart(file, recordAt: recordAt, size: size) {
                guard (0...recordAt).contains(directoryAt) else { throw ArchiveProblem.broken }
                span = endAt - directoryAt
            }
        }
        if span > limit { throw ArchiveProblem.tooMany }
    }

    /// The checks libarchive's read_zip64_eocd makes, which leave out the record's signature.
    private static func zip64DirectoryStart(_ file: Int32, recordAt: Int64, size: Int64) -> Int64? {
        guard let record = read(file, at: recordAt, count: 56) else { return nil }
        let length = word(record, 4, 8) &+ 12
        guard (56...16384).contains(length), recordAt + Int64(length) <= size,
              word(record, 16, 4) == 0, word(record, 20, 4) == 0, word(record, 24, 8) == word(record, 32, 8) else { return nil }
        return Int64(bitPattern: word(record, 48, 8))
    }

    private static func read(_ file: Int32, at offset: Int64, count: Int) -> [UInt8]? {
        guard offset >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let read = bytes.withUnsafeMutableBytes { pread(file, $0.baseAddress, count, off_t(offset)) }
        return read == count ? bytes : nil
    }

    private static func word(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
        (0..<width).reduce(0) { $0 | UInt64(bytes[at + $1]) << (8 * $1) }
    }
}
#endif

#if os(iOS)
import CLibArchive
import Foundation

nonisolated final class ArchivePass {
    private static let chunk = 64 << 10

    private let archive: OpaquePointer
    private let file: Int32
    private let size: Int64
    private let name: String
    private let limits: ArchiveLimits
    private let deadline: ContinuousClock.Instant
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: ArchivePass.chunk, alignment: 16)
    private var stopped: (any Error)?
    private var formatChecked = false

    private init(archive: OpaquePointer, file: Int32, size: Int64, name: String, limits: ArchiveLimits) {
        self.archive = archive
        self.file = file
        self.size = size
        self.name = name
        self.limits = limits
        deadline = .now + limits.timeLimit
    }

    deinit {
        archive_read_free(archive)
        close(file)
        buffer.deallocate()
    }

    static func run<T>(_ url: URL, limits: ArchiveLimits, _ body: (ArchivePass) throws -> T) throws -> T {
        let file = Darwin.open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        let size = lseek(file, 0, SEEK_END)
        guard file >= 0, size >= 0, lseek(file, 0, SEEK_SET) == 0 else {
            if file >= 0 { close(file) }
            throw ArchiveProblem.broken
        }
        guard let archive = archive_read_new() else {
            close(file)
            throw ArchiveProblem.tooLarge
        }
        let pass = ArchivePass(archive: archive, file: file, size: size, name: url.lastPathComponent, limits: limits)
        // libarchive converts names to the thread's locale; in the C locale it drops any that
        // are not ASCII.
        let utf8 = newlocale(LC_CTYPE_MASK, "UTF-8", nil) ?? newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil)
        let previous = uselocale(utf8)
        defer {
            uselocale(previous)
            if let utf8 { freelocale(utf8) }
        }
        try ArchiveZipDirectory.check(file, size: size, limit: limits.maxZipDirectoryBytes)
        try pass.start()
        return try body(pass)
    }

    private func start() throws {
        archive_read_support_filter_gzip(archive)
        archive_read_support_filter_bzip2(archive)
        archive_read_support_filter_xz(archive)
        archive_read_support_format_zip(archive)
        archive_read_support_format_7zip(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
        archive_read_support_format_tar(archive)
        archive_read_support_format_raw(archive)
        archive_read_set_seek_callback(archive) { _, client, offset, whence in
            guard let client else { return -1 }
            return Unmanaged<ArchivePass>.fromOpaque(client).takeUnretainedValue().seek(to: offset, whence: whence)
        }
        let client = Unmanaged.passUnretained(self).toOpaque()
        let opened = archive_read_open2(archive, client, nil, { _, client, buffer in
            guard let client, let buffer else { return -1 }
            return Unmanaged<ArchivePass>.fromOpaque(client).takeUnretainedValue().read(into: buffer)
        }, { _, client, request in
            guard let client else { return 0 }
            return Unmanaged<ArchivePass>.fromOpaque(client).takeUnretainedValue().skip(request)
        }, nil)
        guard opened == ARCHIVE_OK else { throw problem() }
    }

    func nextEntry() throws -> OpaquePointer? {
        var entry: OpaquePointer?
        let result = archive_read_next_header(archive, &entry)
        if result == ARCHIVE_EOF { return nil }
        guard result == ARCHIVE_OK || result == ARCHIVE_WARN, let entry else { throw problem() }
        if !formatChecked {
            formatChecked = true
            // The raw reader takes any bytes at all: only one a compression filter unwrapped is a file.
            if archive_format(archive) == ARCHIVE_FORMAT_RAW, archive_filter_count(archive) < 2 {
                throw ArchiveProblem.unsupported
            }
        }
        return entry
    }

    func path(of entry: OpaquePointer) -> String? {
        if archive_format(archive) == ARCHIVE_FORMAT_RAW {
            return ArchiveReader.normalized((name as NSString).deletingPathExtension)
        }
        guard let raw = archive_entry_pathname(entry) else { return nil }
        return ArchiveReader.normalized(MailCharset.decode(Data(bytes: raw, count: strlen(raw)), label: nil))
    }

    func item(_ entry: OpaquePointer, index: Int, path: String) -> ArchiveItem {
        let type = archive_entry_filetype(entry)
        let isDirectory = type == S_IFDIR
        let problem: ArchiveProblem? = if isDirectory {
            nil
        } else if archive_entry_is_encrypted(entry) != 0 {
            .password
        } else if type == S_IFLNK || archive_entry_hardlink(entry) != nil {
            .link
        } else if type != S_IFREG {
            .unsupported
        } else {
            nil
        }
        return ArchiveItem(
            index: index,
            path: path,
            size: !isDirectory && archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
            modified: archive_entry_mtime_is_set(entry) != 0
                ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil,
            isDirectory: isDirectory,
            problem: problem
        )
    }

    func writeData(to folder: URL, name: String) throws -> URL {
        let directory = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: name, directoryHint: .notDirectory)
        let out = Darwin.open(target.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard out >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw ArchiveProblem.broken
        }
        defer { close(out) }
        do {
            try copyData(to: out)
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func copyData(to out: Int32) throws {
        let (ratioLimit, overflow) = max(size, 1).multipliedReportingOverflow(by: limits.maxRatio)
        var written: Int64 = 0
        while true {
            if let stop = stop() { throw stop }
            let count = archive_read_data(archive, buffer, Self.chunk)
            if count == 0 { return }
            guard count > 0 else { throw problem() }
            written += Int64(count)
            if written > limits.maxEntryBytes || (written > limits.ratioFreeBytes && !overflow && written > ratioLimit) {
                throw ArchiveProblem.tooLarge
            }
            var done = 0
            while done < count {
                let wrote = Darwin.write(out, buffer + done, count - done)
                guard wrote > 0 else { throw ArchiveProblem.broken }
                done += wrote
            }
        }
    }

    private func read(into pointer: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        if let stop = stop() {
            stopped = stop
            return -1
        }
        let count = Darwin.read(file, buffer, Self.chunk)
        pointer.pointee = UnsafeRawPointer(buffer)
        return count
    }

    private func seek(to offset: Int64, whence: Int32) -> Int64 {
        lseek(file, off_t(offset), whence)
    }

    private func skip(_ request: Int64) -> Int64 {
        let here = lseek(file, 0, SEEK_CUR)
        guard here >= 0, request > 0 else { return 0 }
        let target = min(here + request, size)
        return lseek(file, target, SEEK_SET) < 0 ? 0 : target - here
    }

    private func stop() -> (any Error)? {
        if Task.isCancelled { return CancellationError() }
        if ContinuousClock.now > deadline || archive_filter_bytes(archive, 0) > limits.maxScanBytes {
            return ArchiveProblem.tooLarge
        }
        return nil
    }

    private func problem() -> any Error {
        if let stopped { return stopped }
        if archive_errno(archive) == ENOMEM { return ArchiveProblem.tooLarge }
        let message = archive_error_string(archive).map { String(cString: $0) } ?? ""
        if message.localizedCaseInsensitiveContains("encrypt") || message.localizedCaseInsensitiveContains("passphrase") {
            return ArchiveProblem.password
        }
        if archive_format(archive) == 0 || message.localizedCaseInsensitiveContains("unsupported") {
            return ArchiveProblem.unsupported
        }
        return ArchiveProblem.broken
    }
}
#endif

import CryptoKit
import Foundation
import Observation

/// A Moodle file of a course on this device: not there, on its way, there in the version Moodle
/// lists, or failed with the error to show for it.
enum MoodleDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded(URL)
    case failed(message: String)
}

/// What a file a course lists belongs to: a module, by its course module id, or a post.
nonisolated enum MoodleFileOwner: Hashable, Sendable {
    case module(Int)
    case post(Int)

    fileprivate var folderName: String {
        switch self {
        case .module(let id): "m\(id)"
        case .post(let id): "p\(id)"
        }
    }
}

/// The Moodle files downloaded on this device, under `<root>/<account>/<course id>/`. A file
/// downloads once at a time however many screens ask, and goes on when they close. A copy counts
/// only while Moodle lists the version it was downloaded in, which its modification date keeps.
@Observable
@MainActor
final class MoodleFileDownloads {
    typealias Fetch = @Sendable (_ file: MoodleFile, _ progress: @escaping @Sendable (Double) -> Void) async throws -> URL

    static let shared = MoodleFileDownloads(root: DataCache.shared.moodleFilesDir)

    nonisolated let root: URL
    private var progress: [URL: Double] = [:]
    private var failures: [URL: String] = [:]
    /// Moves on when copies land or go, which every state read depends on.
    private var revision = 0
    @ObservationIgnored private var running: [URL: Task<URL?, Never>] = [:]

    init(root: URL) {
        self.root = root
    }

    /// One folder per file of an owner, so two files of one name in different folders of a
    /// module stay apart; the file keeps its name for Quick Look and sharing.
    nonisolated func location(of file: MoodleFile, owner: MoodleFileOwner, courseId: Int, account: String) -> URL {
        let accountFolder = String(account.unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
        let digest = SHA256.hash(data: Data(((file.path ?? "/") + file.name).utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return root
            .appendingPathComponent(accountFolder.isEmpty ? "_" : accountFolder, isDirectory: true)
            .appendingPathComponent(String(courseId), isDirectory: true)
            .appendingPathComponent(owner.folderName, isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
            .appendingPathComponent(Self.safeName(file.name))
    }

    func state(of file: MoodleFile, at location: URL) -> MoodleDownloadState {
        _ = revision
        if let share = progress[location] { return .downloading(progress: share) }
        if Self.hasCopy(of: file, at: location) { return .downloaded(location) }
        if let message = failures[location] { return .failed(message: message) }
        return .notDownloaded
    }

    /// The copy of `file` at `location`, downloading it through `fetch` first when there is none.
    /// A download already on its way is joined. Nil when it fails, is cancelled, or ends after
    /// `isCurrent` turns false, which writes nothing.
    @discardableResult
    func download(_ file: MoodleFile, to location: URL, fetch: @escaping Fetch, isCurrent: @escaping () -> Bool) async -> URL? {
        if Self.hasCopy(of: file, at: location) { return location }
        if let task = running[location] { return await task.value }
        failures[location] = nil
        progress[location] = 0
        let task = Task { await self.transfer(file, to: location, fetch: fetch, isCurrent: isCurrent) }
        running[location] = task
        let copy = await task.value
        if running[location] == task {
            running[location] = nil
            progress[location] = nil
        }
        revision += 1
        return copy
    }

    func cancel(_ location: URL) {
        guard let task = running.removeValue(forKey: location) else { return }
        progress[location] = nil
        task.cancel()
    }

    /// Stops every download, as a sign-out does, so none writes for the account that left.
    func cancelAll() {
        running.values.forEach { $0.cancel() }
        running = [:]
        progress = [:]
        failures = [:]
        revision += 1
    }

    /// The bytes the downloaded files take, counted off the main actor.
    nonisolated func measure() async -> Int {
        let root = root
        return await Task.detached { Self.totalBytes(in: root) }.value
    }

    /// Deletes every downloaded file, stopping the downloads on their way, and returns the bytes
    /// left, which the settings show.
    func clear() async -> Int {
        cancelAll()
        let root = root
        let left = await Task.detached {
            try? FileManager.default.removeItem(at: root)
            return Self.totalBytes(in: root)
        }.value
        revision += 1
        return left
    }

    /// Deletes the copies Moodle has a newer version of.
    func removeOutdated(_ files: [(file: MoodleFile, location: URL)]) {
        let outdated = files.filter { running[$0.location] == nil && Self.hasOutdatedCopy(of: $0.file, at: $0.location) }
        guard !outdated.isEmpty else { return }
        outdated.forEach { try? FileManager.default.removeItem(at: $0.location) }
        revision += 1
    }

    nonisolated static func totalBytes(in root: URL) -> Int {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        var total = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    private func transfer(_ file: MoodleFile, to location: URL, fetch: Fetch, isCurrent: () -> Bool) async -> URL? {
        do {
            let temporary = try await fetch(file) { share in
                Task { @MainActor in self.report(share, for: location) }
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard !Task.isCancelled, isCurrent() else { return nil }
            try Self.place(temporary, at: location, modified: file.modified)
            return location
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled, isCurrent() else { return nil }
            failures[location] = MoodleFirstLoadView.message(for: error)
            AppLogger.breadcrumb("moodle file download failed: \(error)", category: "moodle")
            return nil
        }
    }

    /// Whole percents, so a large file redraws its row a hundred times at most.
    private func report(_ share: Double, for location: URL) {
        guard running[location] != nil else { return }
        let percent = (min(max(share, 0), 1) * 100).rounded(.down) / 100
        if progress[location] != percent { progress[location] = percent }
    }

    private nonisolated static func place(_ temporary: URL, at location: URL, modified: Date?) throws {
        let files = FileManager.default
        try files.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? files.removeItem(at: location)
        try files.moveItem(at: temporary, to: location)
        if let modified {
            try files.setAttributes([.modificationDate: modified], ofItemAtPath: location.path)
        }
    }

    private nonisolated static func hasCopy(of file: MoodleFile, at location: URL) -> Bool {
        guard let copied = modificationDate(at: location) else { return false }
        return file.modified.map { isSameSecond($0, copied) } ?? true
    }

    private nonisolated static func hasOutdatedCopy(of file: MoodleFile, at location: URL) -> Bool {
        guard let copied = modificationDate(at: location), let modified = file.modified else { return false }
        return !isSameSecond(modified, copied)
    }

    private nonisolated static func modificationDate(at location: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: location.path))?[.modificationDate] as? Date
    }

    private nonisolated static func isSameSecond(_ lhs: Date, _ rhs: Date) -> Bool {
        lhs.timeIntervalSince1970.rounded() == rhs.timeIntervalSince1970.rounded()
    }

    /// Moodle cleans file names of slashes already; this keeps a name that slipped through, or
    /// one of only dots, from leaving the file's folder.
    private nonisolated static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.allSatisfy { $0 == "." } ? "file" : cleaned
    }
}

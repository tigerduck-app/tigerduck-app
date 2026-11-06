#if os(iOS)
import Foundation

struct ArchiveFolder: Hashable {
    let path: String
    let name: String
}

struct ArchiveShare: Identifiable {
    let url: URL
    var id: URL { url }
}

@Observable
@MainActor
final class ArchiveBrowserModel {
    enum Phase {
        case loading
        case listed(ArchiveTree, truncatedAt: Int?)
        case failed(ArchiveProblem?)
    }

    let archive: URL
    private(set) var phase = Phase.loading
    private(set) var opening: Int?
    var preview: URL?
    var shared: ArchiveShare?
    var problem: ArchiveProblem?
    @ObservationIgnored private let session: URL
    @ObservationIgnored private let limits: ArchiveLimits
    @ObservationIgnored private var started = false
    @ObservationIgnored private var extracted: [Int: URL] = [:]

    init(archive: URL, session: URL, limits: ArchiveLimits = ArchiveLimits()) {
        self.archive = archive
        self.session = session
        self.limits = limits
    }

    func load() async {
        guard !started else { return }
        started = true
        let archive = archive
        let limits = limits
        do {
            let listing = try await Self.offMain { try ArchiveReader.list(archive, limits: limits) }
            phase = .listed(ArchiveTree(listing.items), truncatedAt: listing.truncated ? listing.items.count : nil)
        } catch is CancellationError {
            started = false
        } catch {
            phase = .failed(error as? ArchiveProblem)
        }
    }

    func open(_ item: ArchiveItem) {
        if let problem = item.problem {
            self.problem = problem
            return
        }
        guard opening == nil else { return }
        if let file = extracted[item.index], FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            show(file)
            return
        }
        opening = item.index
        let archive = archive
        let session = session
        let limits = limits
        Task { [weak self] in
            do {
                let file = try await Self.offMain { try ArchiveReader.extract(item, from: archive, into: session, limits: limits) }
                self?.opened(file, item: item)
            } catch {
                self?.opening = nil
                if !(error is CancellationError) { self?.problem = error as? ArchiveProblem ?? .broken }
            }
        }
    }

    private func opened(_ file: URL, item: ArchiveItem) {
        opening = nil
        extracted[item.index] = file
        show(file)
    }

    func shareArchive() {
        shared = ArchiveShare(url: archive)
    }

    private func show(_ file: URL) {
        // Quick Look runs a page's scripts in the app; such a file goes to the share sheet.
        if ScriptedPreview.isScripted(extension: file.pathExtension, contentType: nil) {
            shared = ArchiveShare(url: file)
        } else {
            preview = file
        }
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

extension ArchiveProblem {
    var reason: String? {
        switch self {
        case .password: String(localized: "file_viewer_archive_password")
        case .unsupported: String(localized: "file_viewer_archive_unsupported")
        case .tooLarge: String(localized: "file_viewer_archive_too_large")
        case .tooMany: String(localized: "file_viewer_archive_too_many")
        case .link: String(localized: "file_viewer_archive_link")
        case .broken: nil
        }
    }
}
#endif

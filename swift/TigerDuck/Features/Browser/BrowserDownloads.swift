import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserDownloads {
    struct Item: Identifiable, Equatable {
        enum State: Equatable { case running, failed }

        let id = UUID()
        let name: String
        let request: URLRequest?
        var received: Int64 = 0
        var expected: Int64?
        var state = State.running
    }

    private(set) var items: [Item] = []
    private(set) var saved: [SavedDownloads.Entry] = []
    let opener = MoodleFileOpener()
    let store: SavedDownloads
    nonisolated let folder: URL
    @ObservationIgnored var failed: URLRequest?
    @ObservationIgnored private var cancels: [UUID: () -> Void] = [:]

    /// A row's size reads to a tenth of a megabyte, so it is redrawn no more often than that.
    private static let smallestStep: Int64 = 100_000

    init(
        store: SavedDownloads = .browser,
        folder: URL = BrowserPage.downloadsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    ) {
        self.store = store
        self.folder = folder
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func item(_ id: UUID) -> Item? {
        items.first { $0.id == id }
    }

    var runningShare: Double? {
        let running = items.filter { $0.state == .running }
        guard !running.isEmpty else { return nil }
        let known = running.filter { $0.expected != nil }
        let expected = known.reduce(0) { $0 + ($1.expected ?? 0) }
        return expected > 0 ? Double(known.reduce(0) { $0 + $1.received }) / Double(expected) : 0
    }

    var canClear: Bool {
        !saved.isEmpty || items.contains { $0.state == .failed }
    }

    func start(_ name: String, request: URLRequest?, cancel: @escaping () -> Void) -> UUID {
        let item = Item(name: name, request: request)
        items.insert(item, at: 0)
        cancels[item.id] = cancel
        return item.id
    }

    func received(_ id: UUID, bytes: Int64, of expected: Int64?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].expected != expected { items[index].expected = expected }
        let step = max((expected ?? 0) / 100, Self.smallestStep)
        let isDone = expected.map { bytes >= $0 } ?? false
        guard bytes - items[index].received >= step || isDone && bytes != items[index].received else { return }
        items[index].received = bytes
    }

    func finish(_ id: UUID, file: URL) async -> URL? {
        cancels[id] = nil
        guard let name = item(id)?.name else { return nil }
        do {
            let entry = try await store.save(file, as: name)
            items.removeAll { $0.id == id }
            saved.removeAll { $0.name == entry.name }
            saved.insert(entry, at: 0)
            return store.url(of: entry)
        } catch {
            AppLogger.breadcrumb("browser download not saved: \(error)", category: "browser")
            _ = fail(id)
            return nil
        }
    }

    /// A download the student cancelled is gone already, so its failure is not one to show.
    func fail(_ id: UUID) -> Bool {
        cancels[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].state = .failed
        return true
    }

    func cancel(_ id: UUID) {
        cancels.removeValue(forKey: id)?()
        forget(id)
    }

    func forget(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func reload() async {
        saved = await store.entries()
    }

    func remove(_ entry: SavedDownloads.Entry) async {
        await store.remove(entry)
        saved = await store.entries()
    }

    func clear() async {
        items.removeAll { $0.state == .failed }
        await store.clear()
        saved = await store.entries()
    }
}

@MainActor
final class BrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    private let page: BrowserPage
    private let certificates: BrowserCertificateCheck
    private var saving: [ObjectIdentifier: (file: URL, mimeType: String?, id: UUID, progress: NSKeyValueObservation)] = [:]

    init(page: BrowserPage, certificates: BrowserCertificateCheck) {
        self.page = page
        self.certificates = certificates
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = page.downloads.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let name = MoodleFileDownloads.safeName(suggestedFilename)
        let downloads = page.downloads
        let id = downloads.start(name, request: download.originalRequest) { [weak download] in download?.cancel(nil) }
        let progress = download.progress.observe(\.completedUnitCount) { @Sendable [weak downloads] progress, _ in
            let (bytes, total) = (progress.completedUnitCount, progress.totalUnitCount)
            Task { @MainActor in downloads?.received(id, bytes: bytes, of: total > 0 ? total : nil) }
        }
        let file = folder.appendingPathComponent(name)
        saving[ObjectIdentifier(download)] = (file, response.mimeType, id, progress)
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let saved = saving.removeValue(forKey: ObjectIdentifier(download)) else { return }
        saved.progress.invalidate()
        let (id, file, mimeType) = (saved.id, saved.file, saved.mimeType)
        Task {
            guard let kept = await page.downloads.finish(id, file: file) else { return }
            page.files.show(downloaded: kept, mimeType: mimeType)
        }
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(BrowserRouting.allowsDownloadRedirect(to: request.url) ? .allow : .cancel)
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        certificates.evaluate(challenge, completionHandler: completionHandler)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        if let saved = saving.removeValue(forKey: ObjectIdentifier(download)) {
            saved.progress.invalidate()
            guard page.downloads.fail(saved.id) else { return }
        }
        page.downloads.failed = download.originalRequest
        let failure = BrowserPage.Failure.download(
            error, refusedHosts: certificates.refusedHosts,
            requestedHost: download.originalRequest?.url?.host(percentEncoded: false).map(TLSPinMatcher.hostName) ?? page.host
        )
        page.failure = certificates.offering(failure, at: BrowserPage.Failure.failingURL(of: error))
    }
}

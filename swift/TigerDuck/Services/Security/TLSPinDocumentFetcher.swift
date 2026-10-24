import Foundation
import os

/// Fetches the signed pin document on a session of its own with system trust only, so a failing
/// pinned host never keeps new pins from arriving; the signature, not TLS, vouches for them.
/// Every failure is silent, and the engine keeps what it has.
nonisolated final class TLSPinDocumentFetcher: @unchecked Sendable {
    typealias Send = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let url = URL.knownGood("https://api.tigerduck.app/.well-known/tigerduck/tls-pins.json")
    static let interval: TimeInterval = 6 * 60 * 60

    static let shared = TLSPinDocumentFetcher(onApplied: {
        #if os(iOS)
        Task { @MainActor in TLSPinWatchBroadcaster.shared.broadcast() }
        #endif
    })

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    private let engine: TLSPinEngine
    private let send: Send
    private let clock: @Sendable () -> Date
    private let onApplied: @Sendable () -> Void
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Security.TLSPin")
    private let lock = NSLock()
    private var lastFetch: Date?

    init(
        engine: TLSPinEngine = .shared,
        send: @escaping Send = { try await TLSPinDocumentFetcher.session.data(for: $0) },
        clock: @escaping @Sendable () -> Date = { Date() },
        onApplied: @escaping @Sendable () -> Void = {}
    ) {
        self.engine = engine
        self.send = send
        self.clock = clock
        self.onApplied = onApplied
    }

    /// At the first foreground of a launch, then at most every six hours.
    func fetchIfDue() async {
        let due = lock.withLock {
            let now = clock()
            if let lastFetch, now.timeIntervalSince(lastFetch) < Self.interval { return false }
            lastFetch = now
            return true
        }
        if due { await fetch(bypassingCache: false) }
    }

    /// After a pin mismatch, past every HTTP cache.
    func refetch() async {
        lock.withLock { lastFetch = clock() }
        await fetch(bypassingCache: true)
    }

    private func fetch(bypassingCache: Bool) async {
        var request = URLRequest(
            url: Self.url,
            cachePolicy: bypassingCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
            timeoutInterval: 10
        )
        if bypassingCache {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        }
        do {
            let (data, response) = try await send(request)
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                logger.error("TLS pin document fetch answered \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public)")
                return
            }
            if engine.acceptDocument(data) == .applied { onApplied() }
        } catch {
            logger.error("TLS pin document fetch failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

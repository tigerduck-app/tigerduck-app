import Foundation
import Testing
@testable import TigerDuck

struct TLSPinDocumentFetcherTests {
    typealias F = TLSPinFixtures

    final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [URLRequest] = []
        var body = F.envelope(F.payload(serial: 100))
        var status = 200
        var failure: URLError?
        var now = F.now
        var applied = 0

        var requests: [URLRequest] { lock.withLock { log } }

        func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
            try lock.withLock {
                log.append(request)
                if let failure { throw failure }
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (body, response)
            }
        }
    }

    private func fetcher(_ server: Server, engine: TLSPinEngine = F.engine()) -> TLSPinDocumentFetcher {
        TLSPinDocumentFetcher(
            engine: engine,
            send: { try server.answer($0) },
            clock: { server.now },
            onApplied: { server.applied += 1 }
        )
    }

    @Test("The foreground fetch runs once, then again only after six hours")
    func theForegroundFetchIsThrottled() async {
        let server = Server()
        let fetcher = fetcher(server)
        await fetcher.fetchIfDue()
        server.now = F.now.addingTimeInterval(6 * 60 * 60 - 1)
        await fetcher.fetchIfDue()
        #expect(server.requests.count == 1)
        server.now = F.now.addingTimeInterval(6 * 60 * 60)
        await fetcher.fetchIfDue()
        #expect(server.requests.count == 2)
        #expect(server.requests.first?.url == TLSPinDocumentFetcher.url)
        #expect(server.requests.first?.timeoutInterval == 10)
    }

    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    @Test("A foreground fetch during another one waits for it instead of sending again")
    func overlappingForegroundFetchesShareOneRequest() async throws {
        let server = Server()
        let gate = Gate()
        let fetcher = TLSPinDocumentFetcher(
            engine: F.engine(),
            send: { request in
                let answer = try server.answer(request)
                await gate.wait()
                return answer
            },
            clock: { server.now }
        )
        async let first: Void = fetcher.fetchIfDue()
        while server.requests.isEmpty { await Task.yield() }
        async let second: Void = fetcher.fetchIfDue()
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        _ = await (first, second)
        #expect(server.requests.count == 1)
    }

    @Test("A failed foreground fetch does not hold back the next one")
    func aFailureDoesNotThrottle() async {
        let server = Server()
        server.failure = URLError(.notConnectedToInternet)
        let fetcher = fetcher(server)
        await fetcher.fetchIfDue()
        server.failure = nil
        server.status = 503
        await fetcher.fetchIfDue()
        server.status = 200
        await fetcher.fetchIfDue()
        await fetcher.fetchIfDue()
        #expect(server.requests.count == 3)
        #expect(server.applied == 1)
    }

    @Test("The fetch session gives up on a trickling server")
    func theSessionBoundsTheWholeFetch() {
        let config = TLSPinDocumentFetcher.session.configuration
        #expect(config.timeoutIntervalForRequest == 10)
        #expect(config.timeoutIntervalForResource == 15)
    }

    @Test("A mismatch refresh skips every HTTP cache")
    func theMismatchRefreshBypassesCaches() async throws {
        let server = Server()
        await fetcher(server).refetch()
        let request = try #require(server.requests.first)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
    }

    @Test("A new document is applied and forwarded; the same one again is not")
    func onlyANewDocumentIsForwarded() async {
        let server = Server()
        let engine = F.engine()
        let fetcher = fetcher(server, engine: engine)
        await fetcher.refetch()
        await fetcher.refetch()
        #expect(server.applied == 1)
        #expect(engine.storedEnvelope == server.body)
    }

    @Test("A refetch counts any HTTP answer as answered and only a transport failure as not")
    func aRefetchReportsWhetherTheServerAnswered() async {
        let server = Server()
        let fetcher = fetcher(server)
        server.status = 503
        #expect(await fetcher.refetch())
        server.status = 404
        #expect(await fetcher.refetch())
        server.failure = URLError(.timedOut)
        #expect(await fetcher.refetch() == false)
    }

    @Test("A failed fetch is silent and keeps the held document")
    func failuresKeepWhatTheEngineHas() async {
        let server = Server()
        let engine = F.engine()
        let held = F.envelope(F.payload(serial: 50))
        engine.acceptDocument(held)
        server.status = 503
        await fetcher(server, engine: engine).refetch()
        server.status = 200
        server.failure = URLError(.timedOut)
        await fetcher(server, engine: engine).refetch()
        #expect(engine.storedEnvelope == held)
        #expect(server.applied == 0)
    }
}

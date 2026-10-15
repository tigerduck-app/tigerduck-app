// `URLProtocol` double and the only test seam into `SettingsDocumentClient`, a concrete actor
// whose `init` takes a `URLSession`. Must stay `nonisolated`: `URLSession` calls `startLoading()`
// synchronously on a background queue. `lock` guards the `nonisolated(unsafe)` queues and logs.
import Foundation
@testable import TigerDuck

nonisolated final class SettingsAPIStub: URLProtocol {
    nonisolated struct StubResponse {
        let statusCode: Int
        let body: Data
        var headerFields: [String: String] = [:]
        /// Fails the request after the stub has logged it, the way a reply lost in transit does.
        var failure: URLError.Code?
        /// Holds the reply back until the gate opens, so a test can act while the request is out.
        var gate: ReplyGate?

        static var noReply: StubResponse {
            StubResponse(statusCode: 0, body: Data(), failure: .networkConnectionLost)
        }
    }

    nonisolated final class ReplyGate: Sendable {
        private let opened = DispatchSemaphore(value: 0)
        func open() { opened.signal() }
        fileprivate func wait() { opened.wait() }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: [StubResponse]] = [:]
    nonisolated(unsafe) private static var requestLog: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var arrivals: [URLRequest] = []

    /// A fresh, never-reused base URL so the queues below are namespaced
    /// per test even when Swift Testing runs tests concurrently.
    static func uniqueBaseURL() -> URL {
        URL(string: "https://settings-stub.invalid/\(UUID().uuidString)/v3")!
    }

    /// A client wired to this stub. Requests never leave the process.
    static func makeClient(
        baseURL: URL,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil }
    ) -> SettingsDocumentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return SettingsDocumentClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: authHeaderProvider
        )
    }

    static func enqueue(_ response: StubResponse, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        responses[url.absoluteString, default: []].append(response)
    }

    static func requests(for url: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requestLog[url.absoluteString] ?? []
    }

    /// Every request to any path under `baseURL`, in the order they arrived, as a server would
    /// take them.
    static func requests(under baseURL: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return arrivals.filter { $0.url?.absoluteString.hasPrefix(baseURL.absoluteString) == true }
    }

    /// `URLSession` may hand a `PUT`/`POST` body to a custom `URLProtocol`
    /// as either `httpBody` or `httpBodyStream` depending on how the
    /// request was constructed — read whichever is present. Reading only
    /// `httpBody` is the trap that makes naive `URLProtocol` body
    /// assertions silently vacuous.
    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let key = url.absoluteString

        Self.lock.lock()
        Self.requestLog[key, default: []].append(request)
        Self.arrivals.append(request)
        let next = Self.responses[key]?.first
        if next != nil {
            Self.responses[key]?.removeFirst()
        }
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        guard let gate = next.gate else {
            reply(next, for: url)
            return
        }
        // A protocol's client takes its calls on the thread that called `startLoading()`, so the
        // held reply goes back to that thread's run loop.
        let held = HeldReply(stub: self, runLoop: CFRunLoopGetCurrent())
        DispatchQueue.global().async {
            gate.wait()
            CFRunLoopPerformBlock(held.runLoop, CFRunLoopMode.defaultMode.rawValue) {
                held.stub.reply(next, for: url)
            }
            CFRunLoopWakeUp(held.runLoop)
        }
    }

    /// Only the loading thread touches these, once the reply is back on its run loop.
    private struct HeldReply: @unchecked Sendable {
        let stub: SettingsAPIStub
        let runLoop: CFRunLoop
    }

    private func reply(_ next: StubResponse, for url: URL) {
        if let failure = next.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: next.statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(next.headerFields) { $1 }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

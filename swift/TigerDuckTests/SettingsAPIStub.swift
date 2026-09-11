// Shared `URLProtocol` double for `SettingsDocumentClient`.
//
// **Do not delete this as redundant.** Two suites drive the real client
// through it and nothing else exercises `SettingsDocumentClient` at all:
//
// - `SettingsDocumentClientTests` — the client's own surface: the
//   `{"schema_version","document","base_revision"}` envelope, 404 → `nil`,
//   409 → `.conflict`, malformed bodies, the `APIVersionGate` hook.
// - `NotificationSettingsSyncTests` — `NotificationSettingsSync` end to
//   end, which reaches the same code paths from above.
//
// `SettingsDocumentClient` is a concrete `actor`, not a protocol, so it
// cannot be swapped for a lightweight fake; its `init` takes a
// `URLSession`, which is the seam this uses.
//
// Explicitly `nonisolated`: this target defaults unannotated declarations
// to `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`), but `startLoading()`
// is invoked by `URLSession` on an arbitrary background queue,
// synchronously — it has no way to `await` its way onto the main actor.
// `nonisolated(unsafe)` on the two dictionaries is the manual-
// synchronization escape hatch (guarded by `lock`), the same justification
// `SettingsDocumentClient.swift` and `NotificationSettingsDocument.swift`
// give for their own explicit `nonisolated`.
//
// Scoped per test via a unique base URL (`SettingsAPIStub.uniqueBaseURL()`)
// rather than one shared queue, so Swift Testing's default parallel test
// execution cannot let one test consume another's canned response.
import Foundation
@testable import TigerDuck

nonisolated final class SettingsAPIStub: URLProtocol {
    nonisolated struct StubResponse {
        let statusCode: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: [StubResponse]] = [:]
    nonisolated(unsafe) private static var requestLog: [String: [URLRequest]] = [:]

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
        let next = Self.responses[key]?.first
        if next != nil {
            Self.responses[key]?.removeFirst()
        }
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: next.statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

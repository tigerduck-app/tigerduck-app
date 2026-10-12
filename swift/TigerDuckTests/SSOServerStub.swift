// `URLProtocol` double for the SSO sign-in flow. Each URL serves its queued answers in order and
// a URL with none fails, so a request the test did not expect shows up as an error and never
// leaves the process. `nonisolated`: `URLSession` calls `startLoading()` on a background queue.
import Foundation

nonisolated final class SSOServerStub: URLProtocol {
    nonisolated struct Answer {
        let status: Int
        let headers: [String: String]
        let body: String
        var followTo: URL?

        static func page(_ html: String, status: Int = 200) -> Answer {
            Answer(status: status, headers: [:], body: html)
        }

        /// A 302 the session sees as the answer, as the SSO probe does with redirects off.
        static func redirect(to location: String) -> Answer {
            Answer(status: 302, headers: ["Location": location], body: "")
        }

        /// A redirect the session follows to `url`, which the stub then answers.
        static func follow(to url: URL) -> Answer {
            Answer(status: 302, headers: ["Location": url.absoluteString], body: "", followTo: url)
        }
    }

    nonisolated struct Request {
        let method: String
        let url: URL
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: [Answer]] = [:]
    nonisolated(unsafe) private static var log: [Request] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SSOServerStub.self]
        return URLSession(configuration: config)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        answers = [:]
        log = []
    }

    static func enqueue(_ answer: Answer, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        answers[url.absoluteString, default: []].append(answer)
    }

    static var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.bodyData(of: request).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Self.lock.lock()
        Self.log.append(Request(method: request.httpMethod ?? "GET", url: url, body: body))
        let answer = Self.answers[url.absoluteString]?.first
        if answer != nil { Self.answers[url.absoluteString]?.removeFirst() }
        Self.lock.unlock()

        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        var headers = answer.headers
        headers["Content-Type"] = "text/html; charset=utf-8"
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        if let target = answer.followTo {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A POST body can arrive as `httpBodyStream` rather than `httpBody`.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

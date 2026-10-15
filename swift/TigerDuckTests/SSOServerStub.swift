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
        var failure: URLError.Code?

        static func page(_ html: String, status: Int = 200) -> Answer {
            Answer(status: status, headers: [:], body: html)
        }

        /// A 302 the session sees as the answer, as the SSO probe does with redirects off.
        static func redirect(to location: String) -> Answer {
            Answer(status: 302, headers: ["Location": location], body: "")
        }

        /// A redirect the session follows to `url`, which the stub then answers.
        static func follow(to url: URL) -> Answer {
            redirect(302, to: url)
        }

        /// A `status` redirect to `url`, proposed as URLSession proposes a server's: a 307 or a
        /// 308 sends the request again with its method and body, any other a GET without a body.
        /// A session that refuses it gets the redirect and `body` as the answer.
        static func redirect(_ status: Int, to url: URL, body: String = "") -> Answer {
            Answer(status: status, headers: ["Location": url.absoluteString], body: body, followTo: url)
        }

        /// A request that ends with `code` instead of an answer, such as one its caller cancelled.
        static func failure(_ code: URLError.Code) -> Answer {
            Answer(status: 0, headers: [:], body: "", failure: code)
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
        let bodyData = Self.bodyData(of: request)
        let body = bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Self.lock.lock()
        Self.log.append(Request(method: request.httpMethod ?? "GET", url: url, body: body))
        let answer = Self.answers[url.absoluteString]?.first
        if answer != nil { Self.answers[url.absoluteString]?.removeFirst() }
        Self.lock.unlock()

        guard let answer else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let failure = answer.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        var headers = answer.headers
        headers["Content-Type"] = "text/html; charset=utf-8"
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        if let target = answer.followTo {
            let proposed = Self.proposal(after: answer.status, of: request, body: bodyData, to: target)
            switch Self.decision(on: response, proposing: proposed, in: task) {
            case .follow(let next):
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
                return
            case .undecided:
                client?.urlProtocol(self, didFailWithError: Self.undecidedRedirect)
                return
            case .refuse:
                break
            }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The request URLSession proposes for a `status` redirect of `request` to `target`.
    private static func proposal(after status: Int, of request: URLRequest, body: Data?, to target: URL) -> URLRequest {
        guard [307, 308].contains(status) else { return URLRequest(url: target) }
        var resent = request
        resent.url = target
        resent.httpBody = body
        return resent
    }

    private enum RedirectDecision {
        case follow(URLRequest)
        case refuse
        /// The delegate's call returned before it decided.
        case undecided
    }

    /// What `task`'s delegate does with the redirect. URLSession asks the delegate too, but leaves a
    /// task whose protocol redirect was refused waiting for its timeout, so the stub asks first and
    /// answers with a refused redirect itself, as a server does. Only a decision made before the
    /// delegate's call returns counts: waiting would hold up the one thread that runs every
    /// `URLProtocol` in the process, and with it every suite's requests.
    private static func decision(
        on response: HTTPURLResponse, proposing proposed: URLRequest, in task: URLSessionTask?
    ) -> RedirectDecision {
        let decides = #selector(
            URLSessionTaskDelegate.urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)
        )
        guard let task, let delegate = task.delegate, delegate.responds(to: decides) else { return .follow(proposed) }
        let decision = Decision()
        // The delegates under test ignore the session they are given.
        delegate.urlSession?(
            URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: proposed
        ) { decision.settle($0) }
        return decision.current
    }

    /// The error of a request whose redirect the task's delegate left undecided, which fails the
    /// test that made it rather than pass for a refusal.
    private static let undecidedRedirect = URLError(.unknown, userInfo: [
        NSLocalizedDescriptionKey:
            "SSOServerStub: the task's delegate returned without deciding the redirect; the stub takes only a decision made during the call",
    ])

    /// A delegate's redirect decision. A completion handler called later, on another thread, finds
    /// the request already failed.
    private final class Decision: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = RedirectDecision.undecided

        func settle(_ request: URLRequest?) {
            lock.lock(); defer { lock.unlock() }
            settled = request.map(RedirectDecision.follow) ?? .refuse
        }

        var current: RedirectDecision {
            lock.lock(); defer { lock.unlock() }
            return settled
        }
    }

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

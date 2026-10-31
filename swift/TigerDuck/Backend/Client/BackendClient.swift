import Foundation
import os

/// One request to the TigerDuck backend's API. `path` holds raw segments, each percent-encoded on
/// its own, so a course key whose course number holds `/` stays one segment.
nonisolated struct BackendRequest: Sendable {
    var method: String
    var path: [String]
    var query: [URLQueryItem] = []
    var body: Data?
    var authenticated = true
    /// Goes without the bearer token when there is no session, instead of failing as not signed in.
    var sendsWithoutSession = false
    /// Statuses besides 2xx that come back as a response instead of an error.
    var accepting: Set<Int> = []
    var acceptsEveryStatus = false
    var headers: [String: String] = [:]
    var timeout: TimeInterval?
    var cachePolicy: URLRequest.CachePolicy?
    var postsCredentials = false
    /// The backend a sign-out's call goes to; nil takes the client's.
    var baseURL: URL?

    init(_ method: String, _ path: String...) {
        self.method = method
        self.path = path.flatMap { $0.split(separator: "/").map(String.init) }
    }

    init(_ method: String, segments: [String]) {
        self.method = method
        self.path = segments
    }

    func json(_ body: some Encodable, encoder: JSONEncoder = BackendClient.encoder) throws -> BackendRequest {
        var request = self
        do {
            request.body = try encoder.encode(body)
        } catch {
            throw PushAPIError.encodingFailed(error)
        }
        return request
    }
}

nonisolated struct BackendResponse: Sendable {
    let data: Data
    let http: HTTPURLResponse

    var status: Int { http.statusCode }

    /// `X-TigerSync-Clock`, the backend's clock in microseconds, which every response carries.
    var serverClock: Int64? { http.value(forHTTPHeaderField: BackendClient.clockHeader).flatMap(Int64.init) }

    func decoded<Response: Decodable>(_ type: Response.Type) throws -> Response {
        do {
            return try BackendClient.decoder.decode(type, from: data)
        } catch {
            throw PushAPIError.decodingFailed(error)
        }
    }

    func jsonObject() throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushAPIError.decodingFailed(NSError(domain: "BackendClient", code: -1))
        }
        return json
    }
}

/// The bearer token for a request, and what a 401 does: `recover` answers whether another token
/// is ready for the one replay.
nonisolated struct BackendAuth: Sendable {
    let header: @Sendable () async -> String?
    let recover: @Sendable (_ refused: String, _ code: String?) async -> Bool

    static func header(_ provider: @escaping @Sendable () async -> String?) -> BackendAuth {
        BackendAuth(header: provider, recover: { _, _ in false })
    }

    static let none = BackendAuth.header { nil }
}

/// Builds every request to the TigerDuck backend's `/v4`, adds the bearer token, maps the error
/// envelope `{"error", "message", ...}` and owns the one refresh after a 401
/// (https://github.com/tigerduck-app/tigerduck-backend/blob/dev/docs/api-v4.md).
nonisolated final class BackendClient: Sendable {
    static let apiVersion = "v4"
    static let clockHeader = "X-TigerSync-Clock"

    let baseURL: @Sendable () -> URL
    private let session: URLSession
    private let auth: BackendAuth
    private let versionGate: APIVersionGate?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Backend.API")

    init(
        baseURL: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession = BackendClient.session,
        auth: BackendAuth = .none,
        versionGate: APIVersionGate? = nil
    ) {
        self.baseURL = baseURL
        self.session = session
        self.auth = auth
        self.versionGate = versionGate
    }

    func hasAuthSession() async -> Bool {
        await auth.header() != nil
    }

    func send(_ request: BackendRequest) async throws -> BackendResponse {
        try await send(request, replayed: false)
    }

    func send<Response: Decodable>(_ request: BackendRequest, as type: Response.Type) async throws -> Response {
        try await send(request).decoded(type)
    }

    /// Sends an edit stamped with its own time. A 409 `clock_ahead` is answered once by stamping
    /// it again from the backend's clock, which that reply carries.
    func sendStamped(
        at stamp: Date, _ make: @Sendable (_ hlc: Int64) throws -> BackendRequest
    ) async throws -> BackendResponse {
        do {
            return try await send(make(PushAPI.clock(of: stamp)))
        } catch PushAPIError.clockAhead(let serverClock?) {
            return try await send(make(serverClock))
        }
    }

    private func send(_ request: BackendRequest, replayed: Bool) async throws -> BackendResponse {
        var urlRequest = try makeURLRequest(request)
        var sent: String?
        if request.authenticated {
            if let header = await auth.header(), !header.isEmpty {
                urlRequest.setValue(header, forHTTPHeaderField: "Authorization")
                sent = header.split(separator: " ").last.map(String.init)
            } else if !request.sendsWithoutSession {
                throw PushAPIError.notSignedIn
            }
        }
        let (data, response) = request.postsCredentials
            ? try await session.data(for: urlRequest, delegate: CredentialPostDelegate())
            : try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw PushAPIError.invalidResponse }
        let answer = BackendResponse(data: data, http: http)
        if (200..<300).contains(http.statusCode) || request.acceptsEveryStatus { return answer }
        let code = Self.errorCode(in: data)
        if http.statusCode == 401, request.authenticated, !replayed, let sent,
           await auth.recover(sent, code) {
            return try await send(request, replayed: true)
        }
        if http.statusCode == 409, code == "clock_ahead" { throw PushAPIError.clockAhead(serverClock: answer.serverClock) }
        if http.statusCode == 409, code == "sync_revision_expired" { throw PushAPIError.syncRevisionExpired }
        if request.accepting.contains(http.statusCode) { return answer }
        let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
        let path = urlRequest.url?.path ?? ""
        logger.error("\(http.statusCode, privacy: .public) \(path, privacy: .private): \(snippet, privacy: .private)")
        await noteVersion(http.statusCode, code: code)
        throw PushAPIError.httpStatus(http.statusCode, body: snippet, sent: sent.map { .init(value: $0) })
    }

    @MainActor private func noteVersion(_ statusCode: Int, code: String?) {
        (versionGate ?? .shared).note(statusCode: statusCode, code: code)
    }

    private func makeURLRequest(_ request: BackendRequest) throws -> URLRequest {
        guard let url = Self.url(base: request.baseURL ?? baseURL(), path: request.path, query: request.query) else {
            throw PushAPIError.invalidResponse
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }
        if let cachePolicy = request.cachePolicy { urlRequest.cachePolicy = cachePolicy }
        return urlRequest
    }

    /// The `/v4` base of a backend: an endpoint set for `/v3`, as earlier builds stored it, names
    /// the same server.
    static func apiBase(_ server: URL) -> URL {
        guard server.lastPathComponent == "v3" else { return server }
        return server.deletingLastPathComponent().appendingPathComponent(apiVersion)
    }

    static func url(base: URL, path: [String], query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: apiBase(base), resolvingAgainstBaseURL: false) else { return nil }
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = ([prefix] + path.map(encoded)).joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// RFC 3986's unreserved characters and `:`, which a course key holds: `urlPathAllowed` also
    /// keeps `/`, `;`, `&` and `=`, which a course number may hold and a server reads as structure.
    static func encoded(_ segment: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~:")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The `error` of a `/v4` error envelope.
    static func errorCode(in body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
    }

    static let session: URLSession = makeSession(resourceTimeout: 30)
    /// A term's course catalog can take longer than the other answers.
    static let catalogSession: URLSession = makeSession(resourceTimeout: 60)
    /// Sign-in and refresh, each with its own timeout.
    static let authSession: URLSession = .shared
    /// The signed TLS pin document's, with system trust only. A pinned handshake waits on the
    /// refetch, so a server that trickles bytes must not hold it.
    static let pinDocumentSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": "TigerDuck-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        ]
        return URLSession(configuration: config)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSecondsFallback
        return decoder
    }()
}

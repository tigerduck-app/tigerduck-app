import Foundation
import os

nonisolated struct BackendRequest: Sendable {
    var method: String
    var segments: [String]
    var query: [URLQueryItem] = []
    var body: Data?
    var authenticated = true
    var sendsWithoutSession = false
    var returnedStatuses: Set<Int> = []
    var acceptsEveryStatus = false
    var headers: [String: String] = [:]
    var timeout: TimeInterval?
    var cachePolicy: URLRequest.CachePolicy?
    var postsCredentials = false
    var baseURLOverride: URL?
    var signIn: SignIn?
    var conditional: ConditionalGet?

    init(_ method: String, _ path: String...) {
        self.method = method
        self.segments = path.flatMap { $0.split(separator: "/").map(String.init) }
    }

    init(_ method: String, segments: [String]) {
        self.method = method
        self.segments = segments
    }

    func sent(for signIn: SignIn) -> BackendRequest {
        var request = self
        request.signIn = signIn
        return request
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

/// The bearer token for a request with the sign-in it was issued for, and what a 401 does:
/// `recover` answers whether another token of that sign-in is ready for the one replay.
/// `BackendClient` sends a request only with a header of the sign-in it was built for, so a
/// request built for none is refused a header that names one.
nonisolated struct BackendAuth: Sendable {
    let header: @Sendable () async -> (value: String, signIn: SignIn?)?
    let recover: @Sendable (_ refused: String, _ code: String?, _ signIn: SignIn) async -> Bool

    /// A header that names no sign-in, for a client whose requests carry no account data.
    static func unbound(_ provider: @escaping @Sendable () async -> String?) -> BackendAuth {
        BackendAuth(header: { await provider().map { ($0, nil) } }, recover: { _, _, _ in false })
    }

    static let none = BackendAuth.unbound { nil }
}

nonisolated final class BackendClient: Sendable {
    static let apiVersion = "v4"

    let baseURL: @Sendable () -> URL
    private let session: URLSession
    private let auth: BackendAuth
    private let versionGate: APIVersionGate?
    private let editClock: @Sendable () -> EditTime
    private let answered = OSAllocatedUnfairLock<[String: (edit: EditTime, at: EditTime)]>(initialState: [:])
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Backend.API")

    init(
        baseURL: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession = BackendClient.session,
        auth: BackendAuth = .none,
        versionGate: APIVersionGate? = nil,
        editClock: @escaping @Sendable () -> EditTime = { EditTime.now() }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.auth = auth
        self.versionGate = versionGate
        self.editClock = editClock
    }

    func hasAuthSession() async -> Bool {
        await auth.header() != nil
    }

    func send(_ request: BackendRequest) async throws -> BackendResponse {
        try await send(request, as: .first)
    }

    func send<Response: Decodable>(_ request: BackendRequest, as type: Response.Type) async throws -> Response {
        try await send(request).decoded(type)
    }

    /// Sends a user's edit with its `age_ms`, measured as it goes out; the backend stamps the edit
    /// with the time it arrives less that age. An edit made while an earlier edit of one of its
    /// `keys` was on its way ages from that send's answer, so it lands after it whatever the two
    /// sends' network delays.
    func sendStamped(
        _ keys: [String], madeAt edit: EditTime, _ make: @Sendable (_ ageMs: Int64) throws -> BackendRequest
    ) async throws -> BackendResponse {
        let since = answered.withLock { answers in
            keys.compactMap { answers[$0] }
                .filter { $0.edit.seconds(until: edit) > 0 && edit.seconds(until: $0.at) > 0 }
                .map(\.at)
        }.reduce(edit) { latest, answer in latest.seconds(until: answer) > 0 ? answer : latest }
        let response = try await send(make(since.ageMilliseconds(at: editClock())))
        let answeredAt = editClock()
        answered.withLock { answers in
            for key in keys { answers[key] = (edit, answeredAt) }
        }
        return response
    }

    private enum Attempt {
        case first
        case replay(after401For: SignIn)

        func signIn(of request: BackendRequest) -> SignIn? {
            switch self {
            case .first: request.signIn
            case .replay(let signIn): signIn
            }
        }
    }

    private func send(_ request: BackendRequest, as attempt: Attempt) async throws -> BackendResponse {
        var urlRequest = try makeURLRequest(request)
        var sent: String?
        var signIn: SignIn?
        if request.signIn?.isCurrent == false { throw PushAPIError.notSignedIn }
        if request.authenticated {
            if let header = await auth.header(), !header.value.isEmpty {
                if header.signIn != attempt.signIn(of: request) { throw PushAPIError.notSignedIn }
                urlRequest.setValue(header.value, forHTTPHeaderField: "Authorization")
                sent = header.value.split(separator: " ").last.map(String.init)
                signIn = header.signIn
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
        if http.statusCode == 401, request.authenticated, case .first = attempt, let sent, let signIn,
           await auth.recover(sent, code, signIn) {
            return try await send(request, as: .replay(after401For: signIn))
        }
        if http.statusCode == 409, code == "sync_revision_expired" { throw PushAPIError.syncRevisionExpired }
        if request.returnedStatuses.contains(http.statusCode) { return answer }
        let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
        let path = urlRequest.url?.path ?? ""
        logger.error("\(http.statusCode, privacy: .public) \(path, privacy: .private): \(snippet, privacy: .private)")
        await noteVersion(http.statusCode, code: code)
        throw PushAPIError.httpStatus(http.statusCode, body: snippet, accessToken: sent.map { .init(value: $0) })
    }

    @MainActor private func noteVersion(_ statusCode: Int, code: String?) {
        (versionGate ?? .shared).note(statusCode: statusCode, code: code)
    }

    private func makeURLRequest(_ request: BackendRequest) throws -> URLRequest {
        guard let url = Self.url(base: request.baseURLOverride ?? baseURL(), path: request.segments, query: request.query) else {
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
        return request.conditional?.request(urlRequest) ?? urlRequest
    }

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

    static func errorCode(in body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
    }

    static let session: URLSession = makeSession(resourceTimeout: 30)
    static let catalogSession: URLSession = makeSession(resourceTimeout: 60)
    static let pinDocumentSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config.refusingDemoRequests())
    }()

    private static func makeSession(resourceTimeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": "TigerDuck-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        ]
        return URLSession(configuration: config.refusingDemoRequests())
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

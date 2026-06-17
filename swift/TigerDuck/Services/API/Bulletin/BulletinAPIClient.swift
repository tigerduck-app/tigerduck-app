import Foundation
import os

/// URLSession-based client for the bulletin HTTP API (v3).
///
/// Public GET endpoints (`/taxonomy`, list, detail) do not require auth.
/// Subscription CRUD endpoints use Bearer auth via `authHeaderProvider`.
final class BulletinAPIClient: Sendable {
    private let baseURLProvider: @Sendable () -> URL
    private let session: URLSession
    /// Returns a `Bearer <token>` string for v3 JWT auth, or `nil` when the
    /// user is not logged in. Falls back to `X-Push-Token` (shared secret)
    /// when nil, preserving backward compatibility for callers that have
    /// not yet wired up an `AuthTokenManager`.
    private let authHeaderProvider: @Sendable () async -> String?
    private let sharedSecretProvider: @Sendable (URL) -> String?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.API")

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil },
        sharedSecretProvider: @escaping @Sendable (URL) -> String? = { PushServerConfig.resolveSharedSecret(for: $0) }
    ) {
        self.baseURLProvider = baseURLProvider
        self.session = session ?? Self.defaultSession()
        self.authHeaderProvider = authHeaderProvider
        self.sharedSecretProvider = sharedSecretProvider
    }

    // MARK: - Public surface

    func getTaxonomy() async throws -> BulletinAPI.TaxonomyResponse {
        try await get(path: "/bulletins/taxonomy", returning: BulletinAPI.TaxonomyResponse.self)
    }

    func listBulletins(
        limit: Int = 30,
        cursor: Int? = nil,
        includeDeleted: Bool = false
    ) async throws -> BulletinAPI.BulletinListResponse {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        if includeDeleted {
            items.append(URLQueryItem(name: "include_deleted", value: "true"))
        }
        return try await get(
            path: "/bulletins",
            query: items,
            returning: BulletinAPI.BulletinListResponse.self
        )
    }

    func getBulletin(id: Int) async throws -> BulletinAPI.BulletinDetail {
        try await get(path: "/bulletins/\(id)", returning: BulletinAPI.BulletinDetail.self)
    }

    // MARK: - Subscription CRUD (v3)

    /// GET /bulletin-subscriptions — list all rules for the authenticated device.
    func getSubscriptions() async throws -> BulletinAPI.SubscriptionsResponse {
        return try await get(
            path: "/bulletin-subscriptions",
            returning: BulletinAPI.SubscriptionsResponse.self
        )
    }

    /// POST /bulletin-subscriptions — create a single rule.
    func createSubscription(
        rule: BulletinAPI.SubscriptionRule
    ) async throws -> BulletinAPI.SubscriptionRule {
        return try await post(
            path: "/bulletin-subscriptions",
            body: rule,
            returning: BulletinAPI.SubscriptionRule.self
        )
    }

    /// PATCH /bulletin-subscriptions/{id} — update a rule.
    func updateSubscription(
        id: Int,
        rule: BulletinAPI.SubscriptionRule
    ) async throws -> BulletinAPI.SubscriptionRule {
        return try await patch(
            path: "/bulletin-subscriptions/\(id)",
            body: rule,
            returning: BulletinAPI.SubscriptionRule.self
        )
    }

    /// DELETE /bulletin-subscriptions/{id} — delete a rule.
    func deleteSubscription(id: Int) async throws {
        try await deleteRequest(path: "/bulletin-subscriptions/\(id)")
    }

    // MARK: - Legacy snapshot PUT (kept for backward compatibility)

    /// PUT snapshot-style replacement. Retained because `BulletinSubscriptionsStore`
    /// still uses the snapshot model. Prefer CRUD methods for new code.
    func putSubscriptions(
        rules: [BulletinAPI.SubscriptionRule]
    ) async throws -> BulletinAPI.SubscriptionsResponse {
        let body = BulletinAPI.SubscriptionsPutRequest(rules: rules)
        return try await put(
            path: "/bulletin-subscriptions",
            body: body,
            returning: BulletinAPI.SubscriptionsResponse.self
        )
    }

    // MARK: - Internals

    private func get<Response: Decodable>(
        path: String,
        query: [URLQueryItem] = [],
        returning _: Response.Type
    ) async throws -> Response {
        // Resolve baseURL once so the secret provider sees the same host
        // the request is actually going to — avoids any window where the
        // override could flip between URL and secret lookups.
        let baseURL = baseURLProvider()
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        await applyAuth(to: &request, baseURL: baseURL)
        let data = try await execute(request)
        return try decode(data, path: path)
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        returning _: Response.Type
    ) async throws -> Response {
        let baseURL = baseURLProvider()
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await applyAuth(to: &request, baseURL: baseURL)
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw BulletinAPIError.encodingFailed(error)
        }
        let data = try await execute(request)
        return try decode(data, path: path)
    }

    private func put<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        returning _: Response.Type
    ) async throws -> Response {
        let baseURL = baseURLProvider()
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await applyAuth(to: &request, baseURL: baseURL)
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw BulletinAPIError.encodingFailed(error)
        }
        let data = try await execute(request)
        return try decode(data, path: path)
    }

    private func patch<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        returning _: Response.Type
    ) async throws -> Response {
        let baseURL = baseURLProvider()
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        await applyAuth(to: &request, baseURL: baseURL)
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw BulletinAPIError.encodingFailed(error)
        }
        let data = try await execute(request)
        return try decode(data, path: path)
    }

    private func deleteRequest(path: String) async throws {
        let baseURL = baseURLProvider()
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        await applyAuth(to: &request, baseURL: baseURL)
        _ = try await execute(request)
    }

    /// Apply auth header. Prefers Bearer token (v3 JWT) when available;
    /// falls back to `X-Push-Token` (shared secret) for legacy compatibility.
    private func applyAuth(to request: inout URLRequest, baseURL: URL) async {
        if let bearer = await authHeaderProvider(), !bearer.isEmpty {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
            return
        }
        if let secret = sharedSecretProvider(baseURL), !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: "X-Push-Token")
        }
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        // Surface the URL host+path before the call so a hung or DNS-failed
        // request still leaves a breadcrumb (the `await` below can block
        // for `timeoutIntervalForResource` without ever logging otherwise).
        let method = request.httpMethod ?? "GET"
        let host = request.url?.host ?? "?"
        let path = request.url?.path ?? "?"
        logger.info("Bulletin.API → \(method, privacy: .public) \(host, privacy: .public)\(path, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Bulletin.API ✗ \(method, privacy: .public) \(host, privacy: .public)\(path, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw BulletinAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            // Body snippet stays .private — error responses occasionally
            // echo headers (incl. X-Push-Token) or correlation tokens that
            // must not be retained in the system log indefinitely.
            logger.error("Bulletin.API \(http.statusCode, privacy: .public) \(path, privacy: .public): \(snippet, privacy: .private)")
            throw BulletinAPIError.httpStatus(http.statusCode, body: snippet)
        }
        logger.info("Bulletin.API ← \(http.statusCode, privacy: .public) \(path, privacy: .public) (\(data.count, privacy: .public)B)")
        return data
    }

    private func decode<Response: Decodable>(_ data: Data, path: String) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Bulletin.API decode failed path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw BulletinAPIError.decodingFailed(error)
        }
    }

    // MARK: - Factory helpers

    private static func resolveURL(baseURL: URL, path: String, query: [URLQueryItem]) throws -> URL {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let full = baseURL.appendingPathComponent(trimmed)
        guard var components = URLComponents(url: full, resolvingAgainstBaseURL: false) else {
            throw BulletinAPIError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw BulletinAPIError.invalidResponse
        }
        return url
    }

    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": "TigerDuck-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        ]
        return URLSession(configuration: config)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSecondsFallback
        return decoder
    }()

    private static func percentEncoded(_ value: String) -> String {
        // Strict allowlist — `urlPathAllowed` keeps `=`, `&`, `:`, `+`, `@`,
        // any of which can path/query-inject if a device id ever embeds
        // them.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        // Encoder fallback returns "" rather than the raw value: in the
        // (vanishingly rare) UTF-16 surrogate-pair failure mode, shipping
        // unencoded bytes into a URL path could path-inject. An empty
        // segment yields a clean 404 instead.
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
            assertionFailure("percentEncoded failed for value of length \(value.count)")
            return ""
        }
        return encoded
    }
}

enum BulletinAPIError: Error, LocalizedError {
    case encodingFailed(Error)
    case decodingFailed(Error)
    case invalidResponse
    case httpStatus(Int, body: String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let error): return String(format: String(localized: "error_bulletin_encoding_failed_format"), error.localizedDescription)
        case .decodingFailed(let error): return String(format: String(localized: "error_bulletin_decoding_failed_format"), error.localizedDescription)
        case .invalidResponse: return String(localized: "error_bulletin_invalid_response")
        case .httpStatus(let code, let body): return String(format: String(localized: "error_bulletin_http_status_format"), code, body)
        }
    }
}

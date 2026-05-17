import Foundation
import os

/// URLSession-based client for the bulletin HTTP API.
///
/// Public GET endpoints (`/taxonomy`, list, detail) do not require the
/// shared secret. Device-scoped subscription endpoints do, so we always
/// attach `X-Push-Token` when one is configured — the server ignores it
/// on the public routes.
final class BulletinAPIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let sharedSecret: String?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.API")

    init(
        baseURL: URL = PushServerConfig.resolveServerURL(),
        session: URLSession? = nil,
        sharedSecret: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session ?? Self.defaultSession()
        self.sharedSecret = sharedSecret.flatMap { $0.isEmpty ? nil : $0 }
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

    func getSubscriptions(deviceId: String) async throws -> BulletinAPI.SubscriptionsResponse {
        let safe = Self.percentEncoded(deviceId)
        return try await get(
            path: "/devices/\(safe)/subscriptions",
            returning: BulletinAPI.SubscriptionsResponse.self
        )
    }

    func putSubscriptions(
        deviceId: String,
        rules: [BulletinAPI.SubscriptionRule]
    ) async throws -> BulletinAPI.SubscriptionsResponse {
        let safe = Self.percentEncoded(deviceId)
        let body = BulletinAPI.SubscriptionsPutRequest(rules: rules)
        return try await put(
            path: "/devices/\(safe)/subscriptions",
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
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)
        let data = try await execute(request)
        return try decode(data, path: path)
    }

    private func put<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        returning _: Response.Type
    ) async throws -> Response {
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: [])
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw BulletinAPIError.encodingFailed(error)
        }
        let data = try await execute(request)
        return try decode(data, path: path)
    }

    private func applyAuth(to request: inout URLRequest) {
        guard let secret = sharedSecret else { return }
        request.setValue(secret, forHTTPHeaderField: "X-Push-Token")
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BulletinAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            // Body snippet stays .private — error responses occasionally
            // echo headers (incl. X-Push-Token) or correlation tokens that
            // must not be retained in the system log indefinitely.
            logger.error("Bulletin.API \(http.statusCode, privacy: .public) \(request.url?.path ?? "", privacy: .public): \(snippet, privacy: .private)")
            throw BulletinAPIError.httpStatus(http.statusCode, body: snippet)
        }
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

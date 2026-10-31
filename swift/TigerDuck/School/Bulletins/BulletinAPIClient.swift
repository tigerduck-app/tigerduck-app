import Foundation
import os

final class BulletinAPIClient: Sendable {
    private let baseURLProvider: @Sendable () -> URL
    private let session: URLSession
    private let authHeaderProvider: @Sendable () async -> String?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.API")

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.baseURLProvider = baseURLProvider
        self.session = session ?? Self.defaultSession()
        self.authHeaderProvider = authHeaderProvider
    }

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

    func getSubscriptions() async throws -> BulletinAPI.SubscriptionsResponse {
        return try await get(
            path: "/bulletin-subscriptions",
            returning: BulletinAPI.SubscriptionsResponse.self
        )
    }

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

    private func get<Response: Decodable>(
        path: String,
        query: [URLQueryItem] = [],
        returning _: Response.Type
    ) async throws -> Response {
        let baseURL = baseURLProvider()
        let url = try Self.resolveURL(baseURL: baseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        await applyAuth(to: &request)
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
        await applyAuth(to: &request)
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw BulletinAPIError.encodingFailed(error)
        }
        let data = try await execute(request)
        return try decode(data, path: path)
    }

    private func applyAuth(to request: inout URLRequest) async {
        if let bearer = await authHeaderProvider(), !bearer.isEmpty {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let method = request.httpMethod ?? "GET"
        let host = request.url?.host ?? "?"
        let path = request.url?.path ?? "?"
        logger.info("Bulletin.API → \(method, privacy: .public) \(host, privacy: .public)\(path, privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Bulletin.API ✗ \(method, privacy: .public) \(host, privacy: .public)\(path, privacy: .public) — \(error.localizedDescription, privacy: .private)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw BulletinAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            logger.error("Bulletin.API \(http.statusCode, privacy: .public) \(path, privacy: .public): \(snippet, privacy: .private)")
            APIVersionGate.shared.note(statusCode: http.statusCode)
            throw BulletinAPIError.httpStatus(http.statusCode, body: snippet)
        }
        logger.info("Bulletin.API ← \(http.statusCode, privacy: .public) \(path, privacy: .public) (\(data.count, privacy: .public)B)")
        return data
    }

    private func decode<Response: Decodable>(_ data: Data, path: String) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Bulletin.API decode failed path=\(path, privacy: .public) error=\(String(describing: error), privacy: .private)")
            throw BulletinAPIError.decodingFailed(error)
        }
    }

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

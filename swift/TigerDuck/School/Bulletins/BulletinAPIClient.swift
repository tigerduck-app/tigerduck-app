import Foundation
import os

final class BulletinAPIClient: Sendable {
    private let backend: BackendClient

    init(backend: BackendClient) {
        self.backend = backend
    }

    convenience init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.init(backend: BackendClient(
            baseURL: baseURLProvider, session: session ?? BackendClient.session, auth: .header(authHeaderProvider)
        ))
    }

    func getTaxonomy() async throws -> BulletinAPI.TaxonomyResponse {
        try await send(BackendRequest("GET", "bulletins", "taxonomy"), authenticated: false)
    }

    func listBulletins(
        limit: Int = 30,
        cursor: Int? = nil,
        includeDeleted: Bool = false
    ) async throws -> BulletinAPI.BulletinListResponse {
        var request = BackendRequest("GET", "bulletins")
        request.query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            request.query.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        if includeDeleted {
            request.query.append(URLQueryItem(name: "include_deleted", value: "true"))
        }
        return try await send(request, authenticated: false)
    }

    func getBulletin(id: Int) async throws -> BulletinAPI.BulletinDetail {
        try await send(BackendRequest("GET", segments: ["bulletins", String(id)]), authenticated: false)
    }

    func getSubscriptions() async throws -> BulletinAPI.SubscriptionsResponse {
        try await send(BackendRequest("GET", "bulletin-subscriptions"), authenticated: true)
    }

    func putSubscriptions(
        rules: [BulletinAPI.SubscriptionRule]
    ) async throws -> BulletinAPI.SubscriptionsResponse {
        let request: BackendRequest
        do {
            request = try BackendRequest("PUT", "bulletin-subscriptions")
                .json(BulletinAPI.SubscriptionsPutRequest(rules: rules))
        } catch PushAPIError.encodingFailed(let error) {
            throw BulletinAPIError.encodingFailed(error)
        }
        return try await send(request, authenticated: true)
    }

    private func send<Response: Decodable>(
        _ request: BackendRequest, authenticated: Bool
    ) async throws -> Response {
        var request = request
        request.authenticated = authenticated
        request.sendsWithoutSession = true
        do {
            return try await backend.send(request, as: Response.self)
        } catch PushAPIError.httpStatus(let code, let body, _) {
            throw BulletinAPIError.httpStatus(code, body: body)
        } catch PushAPIError.decodingFailed(let error) {
            throw BulletinAPIError.decodingFailed(error)
        } catch PushAPIError.invalidResponse {
            throw BulletinAPIError.invalidResponse
        }
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

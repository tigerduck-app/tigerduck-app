import Foundation
import os

/// URLSession-based client for the TigerDuck push server.
///
/// Stateless helpers — safe to recreate per call. Uses a shared ephemeral
/// session so cookies / caches do not leak across app launches. JSON uses
/// ISO-8601 with fractional seconds for Date, matching what the Python
/// server emits from `datetime.isoformat()`.
final class PushAPIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let sharedSecret: String?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.API")

    init(
        baseURL: URL = AppConstants.defaultPushServerURL,
        session: URLSession? = nil,
        sharedSecret: String? = nil
    ) {
        self.baseURL = baseURL
        self.session = session ?? Self.defaultSession()
        // Only keep non-empty secrets — empty strings mean "auth disabled"
        // on the server side, and we want the client to behave identically.
        self.sharedSecret = sharedSecret.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Public surface

    func registerDevice(_ request: PushAPI.DeviceRegisterRequest) async throws -> PushAPI.DeviceRegisterResponse {
        try await post(path: "/devices/register", body: request, returning: PushAPI.DeviceRegisterResponse.self)
    }

    func unregisterDevice(deviceId: String) async throws {
        let body = PushAPI.DeviceUnregisterRequest(deviceId: deviceId)
        _ = try await postExpectingNoBody(path: "/devices/unregister", body: body)
    }

    func syncSchedule(_ request: PushAPI.ScheduleSyncRequest) async throws -> PushAPI.ScheduleSyncResponse {
        try await post(path: "/schedule/sync", body: request, returning: PushAPI.ScheduleSyncResponse.self)
    }

    func cancelSchedule(deviceId: String, sourceId: String) async throws {
        let safeDevice = Self.percentEncoded(deviceId)
        let safeSource = Self.percentEncoded(sourceId)
        let url = baseURL.appendingPathComponent("schedule/\(safeDevice)/\(safeSource)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)
        _ = try await execute(request)
    }

    func ping() async throws {
        let url = baseURL.appendingPathComponent("ping")
        _ = try await execute(URLRequest(url: url))
    }

    // MARK: - Internals

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        returning: Response.Type
    ) async throws -> Response {
        var request = try makePostRequest(path: path, body: body)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await execute(request)
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            logger.error("Push.API decode failed path=\(path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw PushAPIError.decodingFailed(error)
        }
    }

    private func postExpectingNoBody<Request: Encodable>(
        path: String,
        body: Request
    ) async throws -> Data {
        let request = try makePostRequest(path: path, body: body)
        return try await execute(request)
    }

    private func makePostRequest<Request: Encodable>(path: String, body: Request) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw PushAPIError.encodingFailed(error)
        }
        return request
    }

    /// Attach the `X-Push-Token` shared-secret header when one is configured.
    /// No-op for dev builds that leave the secret unset; mirrors the
    /// server's behaviour when `TIGERDUCK_API_SHARED_SECRET` is empty.
    private func applyAuth(to request: inout URLRequest) {
        guard let secret = sharedSecret else { return }
        request.setValue(secret, forHTTPHeaderField: "X-Push-Token")
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PushAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            logger.error("Push.API \(http.statusCode, privacy: .public) \(request.url?.path ?? "", privacy: .public): \(snippet, privacy: .public)")
            throw PushAPIError.httpStatus(http.statusCode, body: snippet)
        }
        return data
    }

    // MARK: - Factory helpers

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
        // `urlPathAllowed` includes `/`, so a source_id like "EE/CS-101"
        // would be spliced into the URL as an extra path segment and the
        // server would 404. Remove it so the value stays one segment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

enum PushAPIError: Error, LocalizedError {
    case encodingFailed(Error)
    case decodingFailed(Error)
    case invalidResponse
    case httpStatus(Int, body: String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed(let error): return "Push encode failed: \(error.localizedDescription)"
        case .decodingFailed(let error): return "Push decode failed: \(error.localizedDescription)"
        case .invalidResponse: return "Push server returned a non-HTTP response."
        case .httpStatus(let code, let body): return "Push server returned HTTP \(code): \(body)"
        }
    }
}

// ISO-8601 decoding helpers live in `Extensions/JSONDecoder+ISO8601.swift`
// so every HTTP client in the app shares the same parsing behaviour.

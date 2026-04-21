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
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.API")

    init(
        baseURL: URL = AppConstants.defaultPushServerURL,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.session = session ?? Self.defaultSession()
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
        do {
            request.httpBody = try Self.encoder.encode(body)
        } catch {
            throw PushAPIError.encodingFailed(error)
        }
        return request
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
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
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

private extension JSONDecoder.DateDecodingStrategy {
    /// Accept both `2026-04-22T02:10:00.123+00:00` and `2026-04-22T02:10:00+00:00`.
    static var iso8601WithFractionalSecondsFallback: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = PushDateFormatters.withFractional.date(from: raw) {
                return date
            }
            if let date = PushDateFormatters.withoutFractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date: \(raw)"
            )
        }
    }
}

private enum PushDateFormatters {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let withoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

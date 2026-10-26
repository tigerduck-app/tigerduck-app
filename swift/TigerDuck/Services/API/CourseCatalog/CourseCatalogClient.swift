import Foundation
import os

/// A term's courses in one language, with its colleges, departments and general-education
/// dimensions, as `GET /v3/course-catalog/{semester}` serves it. The backend builds it in
/// tigerduck-backend's `server/course_catalog/refresh.py`.
nonisolated struct CourseCatalog: Decodable, Sendable {
    nonisolated struct Course: Sendable {
        let row: CourseSearchResult
        let isIntensive: Bool
        let isAlliance: Bool
        let isEnglishTaught: Bool
    }

    nonisolated struct Named: Decodable, Sendable {
        let no: String
        let name: String
    }

    nonisolated struct College: Decodable, Sendable {
        let no: String
        let name: String
        let departments: [Named]
    }

    let courses: [Course]
    let colleges: [College]
    let dimensions: [Named]
}

// The backend adds three flags to the fields `CourseSearchResult` decodes.
nonisolated extension CourseCatalog.Course: Decodable {
    private enum Flag: String, CodingKey {
        case IsIntensive, IsAlliance, IsEnglishTaught
    }

    init(from decoder: any Decoder) throws {
        let flags = try decoder.container(keyedBy: Flag.self)
        self.init(
            row: try CourseSearchResult(from: decoder),
            isIntensive: try flags.decode(Bool.self, forKey: .IsIntensive),
            isAlliance: try flags.decode(Bool.self, forKey: .IsAlliance),
            isEnglishTaught: try flags.decode(Bool.self, forKey: .IsEnglishTaught)
        )
    }
}

/// A catalog's body as the backend sent it, with its ETag, as the device stores it.
nonisolated struct StoredCourseCatalog: Codable, Equatable, Sendable {
    let body: Data
    let etag: String?
}

nonisolated enum CourseCatalogError: Error, LocalizedError {
    /// The backend has not stored the term, or this device has no copy to fall back on.
    case unavailable

    var errorDescription: String? { String(localized: "error_courses_unavailable") }
}

/// Fetches term catalogs. Request construction, auth and errors follow `Push/PushAPIClient.swift`.
struct CourseCatalogClient {
    enum Answer: Sendable {
        case notModified
        case changed(StoredCourseCatalog)
    }

    var baseURLProvider: @Sendable () -> URL = { PushServerConfig.resolveServerURL() }
    var session: URLSession = Self.sharedSession
    let authHeaderProvider: @Sendable () async -> String?

    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CourseCatalog.API")

    func fetch(semester: String, language: String, etag: String?) async throws -> Answer {
        guard let header = await authHeaderProvider(), !header.isEmpty else { throw PushAPIError.notSignedIn }
        let term = semester.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var url = baseURLProvider().appendingPathComponent("course-catalog/\(term)")
        url.append(queryItems: [URLQueryItem(name: "language", value: language)])
        var request = URLRequest(url: url)
        // The ETag is ours to send; URLCache would answer the revalidation itself and hide the 304.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(header, forHTTPHeaderField: "Authorization")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PushAPIError.invalidResponse }
        switch http.statusCode {
        case 304:
            return .notModified
        case 200..<300:
            return .changed(StoredCourseCatalog(body: data, etag: http.value(forHTTPHeaderField: "ETag")))
        case 404:
            throw CourseCatalogError.unavailable
        default:
            let snippet = String(data: data.prefix(512), encoding: .utf8) ?? ""
            Self.logger.error("CourseCatalog.API \(http.statusCode, privacy: .public): \(snippet, privacy: .private)")
            APIVersionGate.shared.note(statusCode: http.statusCode)
            throw PushAPIError.httpStatus(http.statusCode, body: snippet)
        }
    }

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent": "TigerDuck-iOS/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
        ]
        return URLSession(configuration: config)
    }()
}

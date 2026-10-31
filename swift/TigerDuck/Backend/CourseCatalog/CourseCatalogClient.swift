import Foundation
import os

/// A term's courses in one language, with its colleges, departments and general-education
/// dimensions, as `GET /v4/course-catalog/{semester}` serves it. The backend builds it in
/// tigerduck-backend's `server/course_catalog/refresh.py`.
nonisolated struct CourseCatalog: Decodable, Sendable {
    nonisolated struct Course: Sendable {
        let row: CourseSearchResult
        let isIntensive: Bool
        let isAlliance: Bool
        let isEnglishTaught: Bool
        /// What the search compares, made once here so that a keystroke folds no case: the
        /// upper-cased course number, and the lower-cased name and teacher as UTF-8.
        let numberKey: String
        let textKey: [UInt8]

        init(row: CourseSearchResult, isIntensive: Bool, isAlliance: Bool, isEnglishTaught: Bool) {
            self.row = row
            self.isIntensive = isIntensive
            self.isAlliance = isAlliance
            self.isEnglishTaught = isEnglishTaught
            numberKey = row.CourseNo.uppercased()
            textKey = Array("\(row.CourseName)\n\(row.CourseTeacher)".lowercased().utf8)
        }
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

/// Fetches term catalogs.
struct CourseCatalogClient {
    enum Answer: Sendable {
        case notModified
        case changed(StoredCourseCatalog)
    }

    let backend: BackendClient

    init(backend: BackendClient) {
        self.backend = backend
    }

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession = BackendClient.catalogSession,
        authHeaderProvider: @escaping @Sendable () async -> String?
    ) {
        self.init(backend: BackendClient(baseURL: baseURLProvider, session: session, auth: .header(authHeaderProvider)))
    }

    func fetch(semester: String, language: String, etag: String?) async throws -> Answer {
        var request = BackendRequest("GET", segments: ["course-catalog", semester])
        request.query = [URLQueryItem(name: "language", value: language)]
        // The ETag is ours to send; URLCache would answer the revalidation itself and hide the 304.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.headers["If-None-Match"] = etag }
        request.accepting = [304, 404]
        let response = try await backend.send(request)
        switch response.status {
        case 304:
            return .notModified
        case 404:
            throw CourseCatalogError.unavailable
        default:
            return .changed(StoredCourseCatalog(body: response.data, etag: response.http.value(forHTTPHeaderField: "ETag")))
        }
    }
}

import Foundation
import TigerDuckCore

nonisolated enum MoodleWebserviceClient {
    static let webservicePath = "/webservice/rest/server.php"
    static let session: URLSession = {
        let userAgent = (
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
            + "MoodleMobile 5.1.1 (51100)"
        )
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
        ]
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }()

    struct TokenSource: Sendable {
        let stored: @Sendable () async -> String?
        let renew: @Sendable (_ rejected: String?) async throws -> String

        static let keychain = TokenSource(
            stored: { await MoodleTokenService.shared.currentToken() },
            renew: { try await MoodleTokenService.shared.refreshTokenIfNeeded(replacing: $0) }
        )
    }

    /// Runs `body` with the stored token, or a renewed one when none is stored. Once Moodle calls
    /// that token invalid, a renewed one replaces it and `body` runs once more. A call that needs
    /// the token's user id asks for it inside `body`, so a stale token there is renewed too.
    ///
    /// An access error gets one more try with the same token: Moodle answers an expired token
    /// with `accessexception` once and deletes it, then answers `invalidtoken`. A function the
    /// site does not allow fails the same way twice and starts no renewal.
    static func withToken<T>(
        _ tokens: TokenSource = .keychain,
        _ body: (String) async throws -> T
    ) async throws -> T {
        let token = if let stored = await tokens.stored() { stored } else { try await tokens.renew(nil) }
        do {
            do {
                return try await body(token)
            } catch MoodleWebserviceError.accessDenied {
                return try await body(token)
            }
        } catch MoodleWebserviceError.invalidToken {
            return try await body(try await tokens.renew(token))
        }
    }

    /// The answer is decoded off the main actor. A Moodle error body throws its case whatever
    /// the HTTP status, since Moodle sends most errors with a 200. A 503 with `Retry-After` is
    /// Moodle's CLI maintenance page, which an upgrade shows for every request.
    static func call<T: Decodable & Sendable>(
        _ function: String,
        params: [(String, String)] = [],
        token: String,
        as type: T.Type,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> T {
        guard var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid base URL")
        }
        components.path = webservicePath
        components.queryItems = [
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "wsfunction", value: function),
        ]
        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid webservice URL for \(function)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // The token goes in the form, which Moodle reads as it reads the query, so it stays out of
        // the URLs that server and proxy access logs keep.
        request.httpBody = Data(formBody([("wstoken", token)] + params).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: CredentialPostDelegate())
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.malformedResponse(detail: "No HTTP response")
        }
        let status = http.statusCode
        let underMaintenance = status == 503 && http.value(forHTTPHeaderField: "Retry-After") != nil
        return try await Task.detached(priority: .userInitiated) {
            if let moodleError = MoodleWebserviceError.from(jsonData: data) { throw moodleError }
            if underMaintenance { throw MoodleWebserviceError.siteMaintenance }
            guard status == 200 else { throw MoodleWebserviceError.httpStatus(code: status) }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode \(function): \(error)")
            }
        }.value
    }

    static func formBody(_ params: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")
    }
}

struct MoodleEnrolledCourse: Sendable {
    let id: Int
    let fullname: String
    let shortname: String
    let idnumber: String
    let startDate: Date?
    let endDate: Date?

    var courseNo: String {
        guard semester.isEmpty == false else { return "" }
        return String(idnumber.dropFirst(4))
    }

    var semester: String {
        AcademicTerm.codePrefix(ofMoodleId: idnumber) ?? ""
    }

    fileprivate var rawSemesterPrefix: String {
        semester.isEmpty ? "" : String(idnumber.prefix(4))
    }
}

extension MoodleEnrolledCourse {
    private static let courseNoToken = /(?:3?[A-Z]{2,3}|3[A-Z])[0-9][A-Z0-9]{5,6}/

    var courseNos: [String] {
        guard !courseNo.isEmpty else { return [] }
        var seen: Set<String> = [courseNo]
        return [courseNo] + fullname
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap { $0.wholeMatch(of: Self.courseNoToken).map { String($0.output) } }
            .filter { seen.insert($0).inserted }
    }

    var idnumbers: [String] { courseNos.map { rawSemesterPrefix + $0 } }
}

nonisolated struct MoodleAssignmentRecord: Codable, Sendable, Hashable {
    static let cacheName = "assignments"

    let assignId: Int
    let cmId: Int
    let courseId: Int
    let name: String
    let dueDate: Date?
    /// Final cutoff after which submissions are rejected. `nil` when Moodle
    /// sets `cutoffdate == 0`, meaning the assignment keeps accepting late
    /// submissions indefinitely.
    let cutoffDate: Date?
    let allowSubmissionsFromDate: Date?
    let intro: String
    let noSubmissions: Bool
    var introAttachments: [MoodleFile] = []
    var teamSubmission = false

    /// The date this student hands in by. Moodle keeps the assignment's own due date for everyone
    /// and gives a student an extension apart, which counts only when it is later.
    func dueDate(extendedTo extensionDate: Date?) -> Date? {
        dueDate.map { max($0, extensionDate ?? $0) }
    }
}

nonisolated struct MoodleAssignmentSubmission: Codable, Sendable, Equatable {
    let status: String?
    let modified: Date?
    let files: [MoodleFile]
    let onlineText: String?
    let id: Int?
    let takesComments: Bool
    let groupId: Int?
    var groupName: String? = nil
    var comments: [MoodleSubmissionComment]? = nil
    var grade: MoodleAssignmentGrade? = nil
    var extensionDueDate: Date? = nil

    var isSubmitted: Bool { status == "submitted" }
    var submittedAt: Date? { isSubmitted ? modified : nil }
}

nonisolated struct MoodleAssignmentGrade: Codable, Sendable, Equatable {
    let grade: String?
    let gradedAt: Date?
    let feedback: String?
}

nonisolated struct MoodleSubmissionComment: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    let authorName: String
    let created: Date
    let content: String
}

struct MoodleSubmissionStatus: Sendable {
    let assignId: Int
    let submissionStatus: String?
    let gradingStatus: String?
    let submittedAt: Date?
    var extensionDueDate: Date? = nil

    var isSubmitted: Bool {
        submissionStatus == "submitted"
    }
}

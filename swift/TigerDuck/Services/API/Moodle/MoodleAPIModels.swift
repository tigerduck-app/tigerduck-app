import Foundation

// MARK: - Shared webservice session

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
        // SPKI pin on every webservice REST call — every request
        // carries the long-lived `wstoken` as a query string, so an
        // unpinned session over a hostile root CA leaks the token.
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
    }()

    /// Where ``withToken(_:_:)`` reads and renews the Moodle token. Tests pass stand-ins.
    struct TokenSource: Sendable {
        let stored: @Sendable () async -> String?
        /// A token in place of `rejected`, which is nil when none was stored.
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
            URLQueryItem(name: "wstoken", value: token),
        ]
        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid webservice URL for \(function)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formBody(params).utf8)

        let data: Data
        let response: URLResponse
        do {
            // The body can hold a secret, as the autologin key request's private token.
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

    /// `application/x-www-form-urlencoded` with everything outside RFC 3986's unreserved
    /// characters percent-encoded.
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

// MARK: - Enrolled Courses (core_enrol_get_users_courses)

struct MoodleEnrolledCourse: Sendable {
    let id: Int
    let fullname: String
    let shortname: String
    let idnumber: String
    let startDate: Date?
    let endDate: Date?

    /// NTUST course number stripped of the semester prefix.
    /// e.g. "1142PE139B022" → "PE139B022". Empty if idnumber is empty or format unknown.
    var courseNo: String {
        guard semester.isEmpty == false else { return "" }
        return String(idnumber.dropFirst(4))
    }

    /// Semester code extracted from the idnumber prefix, spelled the way
    /// NTUST's own catalogue spells it — see
    /// ``SDCourse/semesterPrefix(ofMoodleId:)``. e.g. "1142PE139B022" →
    /// "1142", "114hGD3115301" → "114H". Empty if the idnumber carries no
    /// recognisable prefix.
    var semester: String {
        SDCourse.semesterPrefix(ofMoodleId: idnumber) ?? ""
    }

    /// The prefix exactly as Moodle wrote it, case and all. ``semester`` is
    /// for comparing against NTUST term codes; this is for rebuilding a
    /// string that has to match a real `idnumber`.
    fileprivate var rawSemesterPrefix: String {
        semester.isEmpty ? "" : String(idnumber.prefix(4))
    }
}

extension MoodleEnrolledCourse {
    /// A co-listed course carries one `idnumber`, the first-listed department's code; the
    /// other department's code appears only in `fullname`. A student enrolled through that code
    /// misses an exact `courseNo` match, and the class table loses its "open in Moodle"
    /// button. The digit after the letters keeps an all-caps English word in a bilingual
    /// title from reading as a course number, and the optional leading `3` is the
    /// continuing-education division form `CourseSelectionService.courseNoRegex` accepts.
    /// Tokens are matched whole: a scan finds `CS3003302` inside `3CS3003302` and would mint
    /// an alias for a course that does not exist.
    private static let courseNoToken = /3?[A-Z]{2,3}[0-9][A-Z0-9]{5,6}/

    /// Every NTUST course number this Moodle course answers to. The one in
    /// `idnumber` comes first and is the authoritative one; co-listed codes
    /// scraped out of `fullname` follow. Empty when `idnumber` has no
    /// recognisable semester prefix, matching ``courseNo``.
    var courseNos: [String] {
        guard !courseNo.isEmpty else { return [] }
        var seen: Set<String> = [courseNo]
        return [courseNo] + fullname
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap { $0.wholeMatch(of: Self.courseNoToken).map { String($0.output) } }
            .filter { seen.insert($0).inserted }
    }

    /// ``courseNos`` with this course's semester prefix put back on each, so
    /// they can be looked up the way ``idnumber`` itself is. Index 0 is
    /// always `idnumber`, so the prefix is Moodle's own spelling rather than
    /// the normalised ``semester``.
    var idnumbers: [String] { courseNos.map { rawSemesterPrefix + $0 } }
}

// MARK: - Assignments (mod_assign_get_assignments)

/// Kept for the signed-in account under ``cacheName`` by each assignment round, so an
/// assignment's page has its description and its course without another call.
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
    /// HTML.
    let intro: String
    let noSubmissions: Bool
    var introAttachments: [MoodleFile] = []
    /// A group hands in one submission for all its members.
    var teamSubmission = false
}

// MARK: - Submission Status (mod_assign_get_submission_status)

/// What the account handed in for an assignment, as its page shows it, with the submission's
/// comments and its group's name where the site lets the app read them, and its grade.
nonisolated struct MoodleAssignmentSubmission: Codable, Sendable, Equatable {
    /// `new`, `draft`, `submitted` or `reopened`; nil before Moodle keeps a record.
    let status: String?
    let modified: Date?
    let files: [MoodleFile]
    /// HTML; nil without any.
    let onlineText: String?
    /// The record comments are kept on; nil before Moodle keeps one.
    let id: Int?
    /// Whether the assignment takes comments on submissions.
    let takesComments: Bool
    /// The group a team assignment's submission is for.
    let groupId: Int?
    var groupName: String? = nil
    /// Nil where the site does not let the app read them.
    var comments: [MoodleSubmissionComment]? = nil
    /// Nil until Moodle shows the student a grade or feedback.
    var grade: MoodleAssignmentGrade? = nil

    var isSubmitted: Bool { status == "submitted" }
    var submittedAt: Date? { isSubmitted ? modified : nil }
}

/// The grade and the grader's feedback on the last attempt, as Moodle shows them to the student.
nonisolated struct MoodleAssignmentGrade: Codable, Sendable, Equatable {
    /// As Moodle writes it, such as "85.00 / 100.00", a letter or a scale's word; nil with only
    /// feedback.
    let grade: String?
    let gradedAt: Date?
    /// HTML; nil without any.
    let feedback: String?
}

nonisolated struct MoodleSubmissionComment: Codable, Sendable, Equatable, Identifiable {
    let id: Int
    /// As Moodle spells it, which at NTUST is "student ID @ name".
    let authorName: String
    let created: Date
    /// HTML.
    let content: String
}

struct MoodleSubmissionStatus: Sendable {
    let assignId: Int
    let submissionStatus: String?
    let gradingStatus: String?
    /// Time the submission was last modified (Moodle `submission.timemodified`).
    /// Used to distinguish on-time vs late submissions.
    let submittedAt: Date?

    /// True if this assignment has been submitted (not just saved as draft).
    var isSubmitted: Bool {
        submissionStatus == "submitted"
    }
}

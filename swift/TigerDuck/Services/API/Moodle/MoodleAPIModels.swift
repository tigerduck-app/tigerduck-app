import Foundation

// MARK: - Shared webservice session

nonisolated enum MoodleWebserviceClient {
    static let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
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
}

// MARK: - Enrolled Courses (core_enrol_get_users_courses)

struct MoodleEnrolledCourse: Sendable {
    let id: Int
    let fullname: String
    let shortname: String
    let idnumber: String
    let startDate: Date?
    let endDate: Date?

    /// NTUST course number stripped of 4-digit semester prefix.
    /// e.g. "1142PE139B022" → "PE139B022". Empty if idnumber is empty or format unknown.
    var courseNo: String {
        guard hasSemesterPrefix else { return "" }
        return String(idnumber.dropFirst(4))
    }

    /// 4-digit semester code extracted from idnumber prefix.
    /// e.g. "1142PE139B022" → "1142". Empty if idnumber doesn't start with 4 digits.
    var semester: String {
        guard hasSemesterPrefix else { return "" }
        return String(idnumber.prefix(4))
    }

    private var hasSemesterPrefix: Bool {
        idnumber.count > 4 && idnumber.prefix(4).allSatisfy(\.isNumber)
    }
}

// MARK: - Assignments (mod_assign_get_assignments)

struct MoodleAssignmentRecord: Sendable {
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
}

// MARK: - Submission Status (mod_assign_get_submission_status)

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

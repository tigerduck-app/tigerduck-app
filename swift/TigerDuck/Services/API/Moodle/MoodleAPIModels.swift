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
    /// A 合開 (co-listed) course carries only ONE `idnumber` — the code of
    /// whichever department is listed first. The second department's code
    /// exists nowhere but the `fullname` text:
    ///
    ///     idnumber  1151AS5140701
    ///     fullname  115.1【半導體研究所】AS5140701 電腦輔助晶片系統設計
    ///               / 【資工系】CS5140701 電腦輔助晶片系統設計
    ///
    /// A student who enrolled through the second code (here CS5140701) is
    /// therefore invisible to any exact match on `courseNo`, which is how
    /// the class table lost its "open in Moodle" button for those courses.
    ///
    /// The digit after the letters is what keeps an all-caps English word in
    /// a bilingual course title from being read as a course number, and the
    /// optional leading `3` is the 進修部 form the rest of the codebase already
    /// accepts (`CourseSelectionService.courseNoRegex`).
    ///
    /// Matched against whole tokens rather than scanned across the string:
    /// scanning finds `CS3003302` *inside* `3CS3003302` and would mint an
    /// alias for a course number that does not exist. Checked against 3697
    /// catalogue rows — whole-token matching returns exactly what scanning
    /// did on all of them, and still recovers the partner code in all 155
    /// co-listed rows.
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

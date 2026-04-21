import Foundation

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

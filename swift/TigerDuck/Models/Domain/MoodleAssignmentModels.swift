import Foundation

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

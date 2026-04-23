import Foundation
import SwiftData

@Model
final class SDAssignment {
    @Attribute(.unique) var assignmentId: String
    var courseNo: String
    var courseName: String
    var title: String
    var dueDate: Date
    var isCompleted: Bool
    var isArchived: Bool
    var isLocallyCompleted: Bool
    var moodleUrl: String?
    /// Final cutoff from Moodle. When `nil`, the assignment keeps accepting
    /// late submissions indefinitely; when non-`nil`, submissions past this
    /// instant are rejected ("逾期拒收").
    var cutoffDate: Date?
    /// Time the submission was last modified on Moodle. When `isCompleted`
    /// is true and this is greater than `dueDate`, the submission was late
    /// ("已遲交").
    var submittedAt: Date?

    init(
        assignmentId: String,
        courseNo: String,
        courseName: String,
        title: String,
        dueDate: Date,
        isCompleted: Bool = false,
        isArchived: Bool = false,
        isLocallyCompleted: Bool = false,
        moodleUrl: String? = nil,
        cutoffDate: Date? = nil,
        submittedAt: Date? = nil
    ) {
        self.assignmentId = assignmentId
        self.courseNo = courseNo
        self.courseName = courseName
        self.title = title
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.isArchived = isArchived
        self.isLocallyCompleted = isLocallyCompleted
        self.moodleUrl = moodleUrl
        self.cutoffDate = cutoffDate
        self.submittedAt = submittedAt
    }

    var isOverdue: Bool {
        !isCompleted && dueDate < Date()
    }

    /// Resolves the presentation status against a given reference time.
    /// Centralising this rule here keeps the UI, tests, and Live Activity
    /// views consistent; they all read the same enum instead of each
    /// re-deriving rules from raw dates.
    func status(now: Date = Date()) -> AssignmentStatus {
        if isCompleted {
            if let submittedAt, submittedAt > dueDate {
                return .submittedLate
            }
            return .submitted
        }
        if isArchived { return .archived }
        if isLocallyCompleted { return .locallyCompleted }
        guard dueDate < now else { return .pending }
        if let cutoffDate, now > cutoffDate {
            return .overdueRejected
        }
        return .overdueAcceptable
    }

    var moodleDeepLink: URL? {
        guard let moodleUrl,
              let targetURL = URL(string: moodleUrl) else {
            return nil
        }

        let redirectTarget = targetURL.path + (targetURL.query.map { "?\($0)" } ?? "")
        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/?:")
        guard let encodedRedirect = redirectTarget.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return targetURL
        }

        return URL(string: "moodlemobile://https://moodle2.ntust.edu.tw?redirect=\(encodedRedirect)")
    }
}

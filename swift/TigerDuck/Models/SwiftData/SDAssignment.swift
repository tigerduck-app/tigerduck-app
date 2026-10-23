import Defaults
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
    var cutoffDate: Date?
    var submittedAt: Date?
    /// Moodle's due date for everyone. `dueDate` is the later of it and the student's extension,
    /// which a round that does not ask Moodle about the assignment again takes from here.
    var originalDueDate: Date?
    var extensionDueDate: Date?
    @Transient var isIgnoredByCourse = false
    @Transient var semester: String? = nil

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
        submittedAt: Date? = nil,
        extensionDueDate: Date? = nil,
        semester: String? = nil
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
        self.originalDueDate = dueDate
        self.extensionDueDate = extensionDueDate
        self.semester = semester
        extend(to: extensionDueDate)
    }

    /// Takes Moodle's latest word on the student's extension: a later, a shorter or no extension.
    func extend(to extensionDate: Date?) {
        let original = originalDueDate ?? dueDate
        extensionDueDate = extensionDate
        dueDate = max(original, extensionDate ?? original)
    }

    var isOverdue: Bool {
        !isCompleted && dueDate < AppClock.now()
    }

    func status(now: Date = AppClock.now()) -> AssignmentStatus {
        if !isCompleted {
            if isArchived { return .archived }
            if isLocallyCompleted { return .locallyCompleted }
        }
        return moodleStatus(now: now)
    }

    func moodleStatus(now: Date = AppClock.now()) -> AssignmentStatus {
        if isCompleted {
            if let submittedAt, submittedAt > dueDate {
                return .submittedLate
            }
            return .submitted
        }
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
        return AppConstants.moodleDeepLink(redirectingTo: redirectTarget)
    }

    var moodleWebURL: URL? {
        guard let moodleUrl else { return nil }
        return URL(string: moodleUrl)
    }

    var moodleOpenURL: URL? {
        #if os(macOS)
        switch Defaults[.macMoodleOpenTarget] {
        case .app: return moodleDeepLink
        case .browser: return moodleWebURL
        }
        #else
        return moodleDeepLink
        #endif
    }
}

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
        !isCompleted && dueDate < AppClock.now()
    }

    /// Resolves the presentation status against a given reference time.
    /// Centralising this rule here keeps the UI, tests, and Live Activity
    /// views consistent; they all read the same enum instead of each
    /// re-deriving rules from raw dates.
    func status(now: Date = AppClock.now()) -> AssignmentStatus {
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
        // Use URLComponents so multi-param redirects (e.g. `id=…&forceview=…`)
        // are encoded as `redirect=…` correctly without us hand-rolling an
        // allowed-character set that risks dropping `=` and `&`.
        let host = AppConstants.moodleBaseURL.host ?? "moodle2.ntust.edu.tw"
        var components = URLComponents()
        components.scheme = "moodlemobile"
        components.host = "https"
        components.path = "//\(host)"
        components.queryItems = [URLQueryItem(name: "redirect", value: redirectTarget)]
        return components.url
    }

    /// HTTPS equivalent of ``moodleDeepLink``. Mirrors `SDCourse.moodleWebURL`
    /// — macOS has no Moodle app, so the deep link fails there; this opens
    /// the same page directly in the default browser.
    var moodleWebURL: URL? {
        guard let moodleUrl else { return nil }
        return URL(string: moodleUrl)
    }

    /// Platform-appropriate URL for opening this assignment in Moodle.
    /// macOS reads `Defaults[.macMoodleOpenTarget]` so users with the
    /// iPad Moodle app installed can opt into the deep link instead of
    /// the HTTPS fallback.
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

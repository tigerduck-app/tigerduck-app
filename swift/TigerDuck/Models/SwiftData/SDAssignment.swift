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
    var moodleUrl: String?

    init(
        assignmentId: String,
        courseNo: String,
        courseName: String,
        title: String,
        dueDate: Date,
        isCompleted: Bool = false,
        moodleUrl: String? = nil
    ) {
        self.assignmentId = assignmentId
        self.courseNo = courseNo
        self.courseName = courseName
        self.title = title
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.moodleUrl = moodleUrl
    }

    var isOverdue: Bool {
        !isCompleted && dueDate < Date()
    }

    var moodleDeepLink: URL? {
        URL(string: "moodlemobile://https://moodle2.ntust.edu.tw?redirect=/mod/assign/view.php?id=\(assignmentId)")
    }
}

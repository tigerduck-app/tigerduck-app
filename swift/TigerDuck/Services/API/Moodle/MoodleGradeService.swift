import Foundation

/// One line of a course's gradebook as `gradereport_user_get_grade_items` shows it to the
/// signed-in student: an activity's grade, a category's subtotal or the course total.
nonisolated struct MoodleGradeItem: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    /// Empty for the course total and a category's subtotal, which Moodle leaves unnamed.
    let name: String
    /// `course` for the course total, `category` for a subtotal, `mod` for an activity and
    /// `manual` for an item the teacher added.
    let type: String
    /// The activity's module, such as `assign` or `quiz`.
    let module: String?
    /// The activity's course module, which its page takes as `id`.
    let cmid: Int?
    /// The grade as the course's settings write it; nil while there is none to show.
    let grade: String?
    let maxGrade: Double?
    let isHidden: Bool
    /// The teacher's feedback as CommonMark; empty without any.
    let feedback: String

    var isCourseTotal: Bool { type == "course" }
    var isCategoryTotal: Bool { type == "category" }
    var isShown: Bool { grade != nil && !isHidden }
}

/// The grade report calls of Moodle's mobile web service. Every call takes the token, so the
/// caller runs it inside `MoodleWebserviceClient.withToken`.
nonisolated enum MoodleGradeService {
    static let gradeItemsFunction = "gradereport_user_get_grade_items"

    /// What Moodle answers when a course keeps its grade report from the student, by a course
    /// setting or a permission: the course has no grades to show, and the fetch did not fail.
    private static let reportWithheld: Set<String> = ["nopermissiontoviewgrades", "nopermissions"]

    /// `userId`'s grade items in `courseId`, in the gradebook's order.
    static func gradeItems(
        courseId: Int,
        userId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleGradeItem] {
        do {
            let answer = try await MoodleWebserviceClient.call(
                gradeItemsFunction,
                params: [("courseid", String(courseId)), ("userid", String(userId))],
                token: token,
                as: RawGradeItems.self,
                session: session,
                siteURL: siteURL
            )
            return answer.usergrades.first { $0.userid == userId }?.gradeitems.map(\.model) ?? []
        } catch MoodleWebserviceError.malformedResponse(let code) where reportWithheld.contains(code) {
            return []
        }
    }
}

// MARK: - Answers

private nonisolated struct RawGradeItems: Decodable, Sendable {
    let usergrades: [RawUserGrades]
}

private nonisolated struct RawUserGrades: Decodable, Sendable {
    let userid: Int
    let gradeitems: [RawGradeItem]
}

private nonisolated struct RawGradeItem: Decodable, Sendable {
    let id: Int
    let itemname: String?
    let itemtype: String
    let itemmodule: String?
    let cmid: Int?
    let graderaw: Double?
    let gradeformatted: String?
    let grademax: Double?
    let gradeishidden: Bool?
    let feedback: String?

    /// Moodle writes "-" for an item not graded yet, puts a pass mark's icon as HTML before a
    /// grade, and sends no `graderaw` for a grade it keeps from the student, such as one hidden
    /// until a date.
    var model: MoodleGradeItem {
        let formatted = MoodleHTMLText.plainText(fromHTML: gradeformatted ?? "")
        return MoodleGradeItem(
            id: id,
            name: MoodleHTMLText.plainText(fromHTML: itemname ?? ""),
            type: itemtype,
            module: itemmodule,
            cmid: cmid,
            grade: graderaw == nil || formatted.isEmpty || formatted == "-" ? nil : formatted,
            maxGrade: grademax,
            isHidden: gradeishidden ?? false,
            feedback: BulletinBodyRenderer.normalize(MoodleHTMLText.markdown(fromHTML: feedback ?? ""))
        )
    }
}

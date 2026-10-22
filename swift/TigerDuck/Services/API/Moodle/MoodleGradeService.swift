import Foundation

nonisolated struct MoodleGradeItem: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
    let type: String
    let module: String?
    let cmid: Int?
    let grade: String?
    let maxGrade: Double?
    let isHidden: Bool
    let feedback: String

    var isCourseTotal: Bool { type == "course" }
    var isCategoryTotal: Bool { type == "category" }
    var isShown: Bool { grade != nil && !isHidden }
}

nonisolated enum MoodleGradeService {
    static let gradeItemsFunction = "gradereport_user_get_grade_items"

    private static let reportWithheld: Set<String> = ["nopermissiontoviewgrades", "nopermissions"]

    static func gradeItems(
        courseId: Int,
        userId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleGradeItem] {
        do {
            let answer = try await MoodleWebserviceClient.call(
    /// What Moodle answers when a course keeps its grade report from the student, by a course
    /// setting or a permission: the course has no grades to show, and the fetch did not fail.
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
    /// Moodle writes "-" for an item not graded yet, puts a pass mark's icon as HTML before a
    /// grade, and sends no `graderaw` for a grade it keeps from the student, such as one hidden
    /// until a date.
}

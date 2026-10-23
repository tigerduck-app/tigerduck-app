import Foundation

/// TAT's share code, which the app reads in versions 1 and 2 and writes in version 2.
/// See docs/decisions/0023-class-table-share-code.md.
nonisolated extension ClassTableShareCode {
    static let tatPrefix = "HTTPS://NTUST-TAT.WEB.APP/S/"

    private static let tatStudentIdLength = 9
    private static let tatCourseNoLength = 9

    /// One character per period of `AppConstants.Periods.chronologicalOrder`, in its order: the
    /// noon period, the app's 5, is `N`, so `5` to `9` stand for the app's 6 to 10.
    private static let tatPeriodCodes = Array("1234N56789ABCD")

    static func decodeTAT(_ code: String) throws -> ClassTableShareCode {
        let body = code.dropFirst(tatPrefix.count)
        let magic = body.prefix(4)
        let format: Format
        switch magic {
        case "TAT2": format = .tat2
        case "TAT1": format = .tat1
        default:
            let isVersion = magic.hasPrefix("TAT") && magic.utf8.count == 4 && isDigits(magic.suffix(1))
            throw isVersion ? ClassTableShareCodeError.unknownVersion : .malformed
        }
        let semester = body.dropFirst(4).prefix(4)
        guard isASCII(body), isSemester(semester) else { throw ClassTableShareCodeError.malformed }

        // A shorter ID is padded with spaces. Trimming a code with no courses takes the padding
        // with it, so the field may come up short.
        var studentId = body.dropFirst(8).prefix(tatStudentIdLength)
        while studentId.last == " " { studentId = studentId.dropLast() }
        guard studentId.isEmpty || isUpperAlphanumerics(studentId) else { throw ClassTableShareCodeError.malformed }

        let courses = body.dropFirst(8 + tatStudentIdLength)
        let chunks = courses.isEmpty ? [] : courses.split(separator: "-", omittingEmptySubsequences: false)
        let courseNos = try chunks.map { chunk in
            let parts = chunk.split(separator: ".", omittingEmptySubsequences: false)
            guard parts[0].utf8.count == tatCourseNoLength, parts.dropFirst().allSatisfy(isTATDay) else {
                throw ClassTableShareCodeError.malformed
            }
            return parts[0]
        }
        return ClassTableShareCode(
            format: format,
            studentId: studentId.isEmpty ? nil : String(studentId),
            sharedAt: nil,
            terms: [Term(semester: String(semester), courseNos: try checkedCourseNos(courseNos))]
        )
    }

    /// TAT's version 2 code for one term of the user's class table, with each course's weekdays
    /// and periods. A course code TAT cannot hold, any but nine characters long, is left out;
    /// nil when no course is left or the student ID is longer than TAT's nine characters.
    @MainActor
    static func encodeTAT(studentId: String, semester: String, courses: [SDCourse]) -> String? {
        let id = studentId.uppercased()
        let term = semester.uppercased()
        guard id.utf8.count <= tatStudentIdLength, isUpperAlphanumerics(id[...]), isSemester(term[...]) else {
            return nil
        }
        var written = Set<String>()
        let chunks = courses.compactMap { course -> String? in
            let courseNo = course.courseNo.uppercased()
            guard courseNo.utf8.count == tatCourseNoLength, CourseSelectionService.isCourseNo(courseNo[...]),
                  written.insert(courseNo).inserted else { return nil }
            return courseNo + course.schedule.keys.sorted().map { weekday in
                tatDay(weekday, periods: course.schedule[weekday] ?? [])
            }.joined()
        }
        guard !chunks.isEmpty else { return nil }
        let paddedId = id.padding(toLength: tatStudentIdLength, withPad: " ", startingAt: 0)
        return tatPrefix + "TAT2" + term + paddedId + chunks.joined(separator: "-")
    }

    /// `.`, the weekday from `1` (Monday) to `7`, and the day's periods; empty for a weekday
    /// out of range or a day with no period TAT can hold.
    private static func tatDay(_ weekday: Int, periods: [String]) -> String {
        let order = AppConstants.Periods.chronologicalOrder
        let indices = Set(periods.compactMap { order.firstIndex(of: $0) }).sorted()
        guard (1...7).contains(weekday), !indices.isEmpty else { return "" }
        return "." + String(weekday) + String(indices.map { tatPeriodCodes[$0] })
    }

    private static func isTATDay(_ part: Substring) -> Bool {
        guard let weekday = part.first, ("1"..."7").contains(weekday), part.count > 1 else { return false }
        return part.dropFirst().allSatisfy(tatPeriodCodes.contains)
    }
}

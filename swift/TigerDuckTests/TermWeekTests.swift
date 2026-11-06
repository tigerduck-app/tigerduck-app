import Defaults
import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

struct TermWeekTests {
    private static func taipei(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 0) -> Date {
        TaipeiTime.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static let calendar = AcademicCalendar(
        revision: 1,
        terms: [
            SemesterTerm(code: "1151", start: taipei(2026, 9, 16, 0), end: taipei(2027, 1, 15, 0)),
            SemesterTerm(code: "1152", start: taipei(2027, 2, 22, 0), end: taipei(2027, 6, 18, 0)),
        ],
        holidays: []
    )

    private static func week(_ term: String = "1151", on day: Date) -> Int? {
        calendar.week(of: term, on: day)
    }

    @Test("week 1 is the Monday-to-Sunday week holding a first day in mid-week")
    func firstWeek() {
        #expect(Self.week(on: Self.taipei(2026, 9, 16, 0)) == 1)
        #expect(Self.week(on: Self.taipei(2026, 9, 20, 23, 59)) == 1)
        #expect(Self.week(on: Self.taipei(2026, 9, 21, 0)) == 2)
    }

    @Test("the week turns at midnight between Sunday and Monday in Taipei")
    func mondayBoundary() {
        #expect(Self.week(on: Self.taipei(2026, 11, 1, 23, 59)) == 7)
        #expect(Self.week(on: Self.taipei(2026, 11, 2, 0)) == 8)
        #expect(Self.week(on: Date(timeIntervalSince1970: 1_793_548_799)) == 7)
        #expect(Self.week(on: Date(timeIntervalSince1970: 1_793_548_800)) == 8)
    }

    @Test("the term's last day is in its last week and the day after has none")
    func lastWeek() {
        #expect(Self.week(on: Self.taipei(2027, 1, 11, 0)) == 18)
        #expect(Self.week(on: Self.taipei(2027, 1, 15, 23, 59)) == 18)
        #expect(Self.week(on: Self.taipei(2027, 1, 16, 0)) == nil)
    }

    @Test("a day before the first one has no week, week 1's Monday and Tuesday included")
    func beforeTheTerm() {
        #expect(Self.week(on: Self.taipei(2026, 9, 15, 23, 59)) == nil)
        #expect(Self.week(on: Self.taipei(2026, 9, 14, 0)) == nil)
        #expect(Self.week(on: Self.taipei(2026, 8, 1)) == nil)
    }

    @Test("a term today is not in gives no week, nor does one the calendar lacks or an empty calendar")
    func otherTerms() {
        let friday = Self.taipei(2026, 11, 6)
        #expect(Self.week(on: friday) == 8)
        #expect(Self.week("1152", on: friday) == nil)
        #expect(Self.week("1142", on: friday) == nil)
        #expect(Self.week("1151", on: Self.taipei(2027, 3, 1)) == nil)
        #expect(Self.week("1152", on: Self.taipei(2027, 3, 1)) == 2)
        #expect(AcademicCalendar.empty.week(of: "1151", on: friday) == nil)
    }
}

@MainActor
struct ClassTableWeekShownTests {
    private static func shareCode(_ studentId: String, semester: String) -> ClassTableShareCode {
        ClassTableShareCode(
            format: .tigerDuck, studentId: studentId, sharedAt: nil,
            terms: [ClassTableShareCode.Term(semester: semester, courseNos: ["CS1010001"])]
        )
    }

    private static func answered(_ term: String) throws -> CourseChanges {
        try CourseChanges(json: Data(#"{"term":"\#(term)","changes":[]}"#.utf8))
    }

    @Test("the week shows only with today's mark: course changes answered and the shown term current, another student's too")
    func weekFollowsTodaysMark() async throws {
        try await withExclusiveRealDefaults {
            let storedPick = Defaults[.classTableSelectedSemester]
            defer { Defaults[.classTableSelectedSemester, for: testSignIn] = storedPick }
            let root = FileManager.default.temporaryDirectory.appending(path: "ClassTableWeekShownTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let people = ImportedClassTableStore(fileURL: root.appending(path: "imported.json"), signedInStudentId: { "B11300000" })
            let viewModel = ClassTableViewModel(courses: CourseStore(folders: CacheFolders(root: root)), importedTables: people)
            let current = SchoolTerms.current
            var asked: [String] = []
            let termWeek: (String, Date) -> Int? = { term, _ in
                asked.append(term)
                return 8
            }
            let now = AppClock.now()

            viewModel.pickSemester(current, for: AccountSession.school.currentSignIn)
            viewModel.grid.courseChanges = .empty
            #expect(viewModel.week(on: now, termWeek: termWeek) == nil)
            viewModel.grid.courseChanges = try Self.answered(current)
            #expect(viewModel.week(on: now, termWeek: termWeek) == 8)
            #expect(asked.last == current)

            viewModel.pickSemester("1001", for: AccountSession.school.currentSignIn)
            viewModel.grid.courseChanges = try Self.answered(current)
            #expect(viewModel.week(on: now, termWeek: termWeek) == nil)

            let person = try #require(people.add(Self.shareCode("B11300001", semester: current), nickname: "Ming", courses: [:], for: testSignIn))
            people.show(person.id)
            viewModel.showShownTable()
            viewModel.grid.courseChanges = try Self.answered(current)
            #expect(viewModel.currentSemester == current)
            #expect(viewModel.week(on: now, termWeek: termWeek) == 8)
            #expect(asked.last == current)
        }
    }
}

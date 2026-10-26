import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseSyllabusTests {
    private final class Token {}

    private static func fixture(_ name: String) throws -> CourseSyllabus? {
        let url = try #require(Bundle(for: Token.self).url(forResource: name, withExtension: "json"))
        return try CourseLookupService.decodeSyllabus(Data(contentsOf: url))
    }

    private typealias Part = CourseSyllabusBreakdown.Part

    private static func key(_ language: String = "zh") -> CourseLookupService.LookupKey {
        CourseLookupService.LookupKey(semester: "1151", courseNo: "T\(UUID().uuidString)", language: language)
    }

    @Test("a syllabus shows its fields trimmed, with the textbook and references together")
    func fieldsAreTrimmed() throws {
        let syllabus = try #require(try Self.fixture("CourseSyllabusGraded"))

        #expect(syllabus.grading == "期中考：30%\n期末考：40%\n作業：30%")
        #expect(syllabus.outline == "1.池塘概論\n2.鴨子如何游泳")
        #expect(syllabus.content == "講授與實作")
        #expect(syllabus.references == "鴨子入門，第二版\n\n池塘手冊")
        #expect(syllabus.notes == nil)
        #expect(syllabus.objectives == nil)
        #expect(syllabus.website == nil)
        #expect(syllabus.hasContent)
    }

    @Test("an alliance course shows its code, its note and the other school's page")
    func allianceCourse() throws {
        let syllabus = try #require(try Self.fixture("CourseSyllabusAlliance"))

        #expect(syllabus.outline == "ZZZ0001")
        #expect(syllabus.content == "Partner school course")
        #expect(syllabus.website == URL(string: "https://example.edu.tw/syllabus?code=ZZZ0001"))
        #expect(syllabus.grading == nil)
        #expect(CourseSyllabusBreakdown.teaching(syllabus) == nil)
        #expect(syllabus.hasContent)
    }

    @Test("a syllabus with only blank fields has nothing to show")
    func blankSyllabus() throws {
        let syllabus = try #require(try Self.fixture("CourseSyllabusBlank"))
        #expect(!syllabus.hasContent)
    }

    @Test("an empty answer and the exception for an unknown course are no syllabus, and other errors throw")
    func unknownCourse() throws {
        #expect(try CourseLookupService.decodeSyllabus(Data("[]".utf8)) == nil)
        let unknown = #"{"ClassName":"System.IndexOutOfRangeException","Message":"no row","Data":null}"#
        #expect(try CourseLookupService.decodeSyllabus(Data(unknown.utf8)) == nil)
        #expect(throws: DecodingError.self) {
            try CourseLookupService.decodeSyllabus(Data(#"{"ClassName":"System.TimeoutException"}"#.utf8))
        }
        #expect(throws: DecodingError.self) { try CourseLookupService.decodeSyllabus(Data("<html>".utf8)) }
    }

    @Test("a number reads as its digits and a field of another type as blank")
    func lenientFields() throws {
        let syllabus = try #require(try Self.fixture("CourseSyllabusNumeric"))

        #expect(syllabus.grading == nil)
        #expect(syllabus.notes == "3")
        #expect(syllabus.outline == "Counting ducks.")
        #expect(CourseSyllabusBreakdown.teaching(syllabus) == [
            Part(label: String(localized: "course_detail_syllabus_lecture"), percent: 60),
            Part(label: String(localized: "course_detail_syllabus_case_study"), percent: 12.5),
            Part(label: String(localized: "course_detail_syllabus_practical"), percent: 27.5),
        ])
    }

    @Test("a syllabus is fetched once per term, course and language, even when there is none")
    func syllabiAreKept() async throws {
        var calls = 0
        let fetch: () async throws -> CourseSyllabus? = {
            calls += 1
            return nil
        }
        let key = Self.key()

        _ = try await CourseLookupService.keptSyllabus(key, fetch: fetch)
        _ = try await CourseLookupService.keptSyllabus(key, fetch: fetch)
        #expect(calls == 1)

        let english = CourseLookupService.LookupKey(semester: key.semester, courseNo: key.courseNo, language: "en")
        _ = try await CourseLookupService.keptSyllabus(english, fetch: fetch)
        #expect(calls == 2)
    }

    @Test("callers asking at once for one syllabus share its fetch")
    func concurrentCallersShareOneFetch() async throws {
        var calls = 0
        let fetch: () async throws -> CourseSyllabus? = {
            calls += 1
            try await Task.sleep(for: .milliseconds(50))
            return nil
        }
        let key = Self.key()

        async let first = CourseLookupService.keptSyllabus(key, fetch: fetch)
        async let second = CourseLookupService.keptSyllabus(key, fetch: fetch)
        _ = try await (first, second)

        #expect(calls == 1)
    }

    @Test("a failed fetch is not kept")
    func failuresAreNotKept() async throws {
        let key = Self.key()
        await #expect(throws: URLError.self) {
            try await CourseLookupService.keptSyllabus(key) { throw URLError(.timedOut) }
        }
        let syllabus = try Self.fixture("CourseSyllabusGraded")
        #expect(try await CourseLookupService.keptSyllabus(key) { syllabus } == syllabus)
    }

    @Test("grading lines split at line breaks and list separators")
    func gradingSplits() {
        #expect(CourseSyllabusBreakdown.grading("期中考 30%\r\n期末考 40%\n作業 30%") == [
            Part(label: "期中考", percent: 30), Part(label: "期末考", percent: 40), Part(label: "作業", percent: 30),
        ])
        #expect(CourseSyllabusBreakdown.grading("Midterm 30%; Final - 40%, Homework=20%，Quiz 5%、Lab (5%)") == [
            Part(label: "Midterm", percent: 30), Part(label: "Final", percent: 40),
            Part(label: "Homework", percent: 20), Part(label: "Quiz", percent: 5), Part(label: "Lab", percent: 5),
        ])
    }

    @Test("full-width colons and percent signs, decimals and list numbers read as parts")
    func gradingForms() {
        #expect(CourseSyllabusBreakdown.grading("1.期中考：30％\n2.報告：12.5%\n(3) 出席: 57.5 %") == [
            Part(label: "期中考", percent: 30), Part(label: "報告", percent: 12.5), Part(label: "出席", percent: 57.5),
        ])
    }

    @Test("a part without a percentage, a label too long or no label leaves the text as written")
    func gradingFallsBack() {
        #expect(CourseSyllabusBreakdown.grading("期中考 30%\n課堂參與") == nil)
        #expect(CourseSyllabusBreakdown.grading("期中考 30%以上") == nil)
        #expect(CourseSyllabusBreakdown.grading("100%") == nil)
        #expect(CourseSyllabusBreakdown.grading("  \n ") == nil)
        let twenty = String(repeating: "鴨", count: 20)
        #expect(CourseSyllabusBreakdown.grading("\(twenty) 100%") == [Part(label: twenty, percent: 100)])
        #expect(CourseSyllabusBreakdown.grading("\(twenty)子 100%") == nil)
    }

    @Test("an Instruction value is trimmed and loses its percent sign, and anything else counts as 0")
    func shares() {
        #expect(CourseSyllabusBreakdown.share(" 60 ") == 60)
        #expect(CourseSyllabusBreakdown.share("20%") == 20)
        #expect(CourseSyllabusBreakdown.share("12.5 ％") == 12.5)
        #expect(CourseSyllabusBreakdown.share("") == 0)
        #expect(CourseSyllabusBreakdown.share(nil) == 0)
        #expect(CourseSyllabusBreakdown.share("half") == 0)
        #expect(CourseSyllabusBreakdown.share("-5") == 0)
        #expect(CourseSyllabusBreakdown.share("nan") == 0)
    }

    @Test("teaching methods above 0 show in order")
    func teachingMethods() throws {
        let syllabus = try #require(try Self.fixture("CourseSyllabusGraded"))
        #expect(CourseSyllabusBreakdown.teaching(syllabus) == [
            Part(label: String(localized: "course_detail_syllabus_lecture"), percent: 60),
            Part(label: String(localized: "course_detail_syllabus_case_study"), percent: 20),
            Part(label: String(localized: "course_detail_syllabus_practical"), percent: 20),
        ])
    }

    @Test("Others joins the bar when its text ends in a percentage, and is a row of text otherwise")
    func teachingOthers() {
        let others = String(localized: "course_detail_syllabus_other")
        #expect(CourseSyllabusBreakdown.teaching(Self.teaching(lecture: "80", other: "Pond visit 20%")) == [
            Part(label: String(localized: "course_detail_syllabus_lecture"), percent: 80),
            Part(label: others, percent: 20, detail: "Pond visit"),
        ])
        #expect(CourseSyllabusBreakdown.teaching(Self.teaching(lecture: "0", other: " Pond visit ")) == [
            Part(label: others, percent: nil, detail: "Pond visit"),
        ])
        #expect(CourseSyllabusBreakdown.teaching(Self.teaching(lecture: "0", other: " ")) == nil)
        let prose = String(repeating: "Ducks swim across the pond. ", count: 8) + "10%"
        #expect(CourseSyllabusBreakdown.teaching(Self.teaching(lecture: "0", other: prose)) == [
            Part(label: others, percent: nil, detail: prose),
        ])
    }

    private static func teaching(lecture: String, other: String) -> CourseSyllabus {
        CourseSyllabus(
            CourseGrading: nil, CourseObject: nil, CourseContent: nil, CourseTextbook: nil, CourseRefbook: nil,
            CourseNote: nil, CoreAbility: nil, CourseURL: nil,
            Instruction_1: lecture, Instruction_2: "", Instruction_3: nil, Instruction_4: "0", Instruction_other: other
        )
    }
}

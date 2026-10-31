import Foundation
import Testing
import TigerDuckCore

struct AcademicTermTests {
    private func taipei(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        TaipeiTime.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func aCodeReadsItsYearAndSeason() {
        #expect(AcademicTerm(code: "1141") == AcademicTerm(year: 114, season: .first))
        #expect(AcademicTerm(code: "1142") == AcademicTerm(year: 114, season: .second))
        #expect(AcademicTerm(code: "114H") == AcademicTerm(year: 114, season: .summer))
        #expect(AcademicTerm(code: "114h") == AcademicTerm(year: 114, season: .summer))
        #expect(AcademicTerm(code: "99 1") == AcademicTerm(year: 99, season: .first))
        #expect(AcademicTerm(code: "991") == AcademicTerm(year: 99, season: .first))
        for bad in ["", "H", "1143", "114X", "abc1"] {
            #expect(AcademicTerm(code: bad) == nil)
        }
    }

    @Test func aCodeIsWrittenUnpaddedWithAnUpperCaseSummer() {
        #expect(AcademicTerm(code: "114h")?.code == "114H")
        #expect(AcademicTerm(code: "99 2")?.code == "992")
        #expect(AcademicTerm(year: 115, season: .first).code == "1151")
    }

    @Test func theYearOfACodeIsReadNumerically() {
        #expect(AcademicTerm.year(of: "1151") == 115)
        #expect(AcademicTerm.year(of: "114H") == 114)
        #expect(AcademicTerm.year(of: "99 1") == 99)
        #expect(AcademicTerm.year(of: "114X") == 114)
        #expect(AcademicTerm.year(of: "") == nil)
        #expect(AcademicTerm.year(of: "H") == nil)
    }

    @Test func aSummerTermFollowsItsYearsSecondTerm() {
        let codes = ["1151", "114H", "1142", "1141", "113H", "99 2", "1001", "98 2", "99 1", "99 H"]
        let sorted = codes.compactMap(AcademicTerm.init(code:)).sorted().map(\.code)
        #expect(sorted == ["982", "991", "992", "99H", "1001", "113H", "1141", "1142", "114H", "1151"])
        #expect(AcademicTerm(code: "114H")! > AcademicTerm(code: "1142")!)
        #expect(AcademicTerm(code: "114H")! < AcademicTerm(code: "1151")!)
    }

    @Test func aWalkBackSkipsSummerTerms() {
        #expect(AcademicTerm(code: "1151")!.previousRegular.code == "1142")
        #expect(AcademicTerm(code: "1142")!.previousRegular.code == "1141")
        #expect(AcademicTerm(code: "114H")!.previousRegular.code == "1142")
        #expect(AcademicTerm(code: "1001")!.previousRegular.code == "992")
        #expect(AcademicTerm(code: "1141")!.nextRegular.code == "1142")
        #expect(AcademicTerm(code: "1142")!.nextRegular.code == "1151")
        #expect(AcademicTerm(code: "114H")!.nextRegular.code == "1151")
    }

    @Test func theCachedTermWalkLeavesASummerOrUnreadableCodeAlone() {
        #expect(AcademicTerm.previousRegularCode("1141") == "1132")
        #expect(AcademicTerm.previousRegularCode("1142") == "1141")
        #expect(AcademicTerm.previousRegularCode("1001") == "992")
        #expect(AcademicTerm.previousRegularCode("114H") == "114H")
        #expect(AcademicTerm.previousRegularCode("X") == "X")
        #expect(AcademicTerm.previousRegularCode("") == "")
    }

    @Test func theAcademicYearTurnsOverOnTheFirstOfAugustInTaipei() {
        #expect(AcademicTerm.academicYear(at: taipei(2026, 7, 31, 23)) == 114)
        #expect(AcademicTerm.academicYear(at: taipei(2026, 8, 1, 0)) == 115)
        #expect(AcademicTerm.academicYear(at: taipei(2027, 1, 15)) == 115)
        #expect(AcademicTerm.academicYear(at: taipei(2025, 12, 31, 23)) == 114)
    }

    @Test func theMonthEstimatesTheTerm() {
        #expect(AcademicTerm.estimated(on: taipei(2026, 1, 31)).code == "1141")
        #expect(AcademicTerm.estimated(on: taipei(2026, 2, 1)).code == "1142")
        #expect(AcademicTerm.estimated(on: taipei(2026, 7, 31, 23)).code == "1142")
        #expect(AcademicTerm.estimated(on: taipei(2026, 8, 1, 0)).code == "1151")
        #expect(AcademicTerm.estimated(on: taipei(2026, 12, 31)).code == "1151")
    }

    @Test func aMoodleIdsTermPrefixIsUpperCased() {
        #expect(AcademicTerm.codePrefix(ofMoodleId: "1151AS5140701") == "1151")
        #expect(AcademicTerm.codePrefix(ofMoodleId: "114hGD3115301") == "114H")
        #expect(AcademicTerm.codePrefix(ofMoodleId: "114HGD3115301") == "114H")
        #expect(AcademicTerm.codePrefix(ofMoodleId: "1143GD3115301") == "1143")
        #expect(AcademicTerm.codePrefix(ofMoodleId: "moodle:42") == nil)
        #expect(AcademicTerm.codePrefix(ofMoodleId: "1151") == nil)
        #expect(AcademicTerm.codePrefix(ofMoodleId: "") == nil)
    }

    @Test func aFourCharacterCodeIsShownWithItsYearAsWritten() {
        #expect(AcademicTerm.label(of: "1142") == "114-2")
        #expect(AcademicTerm.label(of: "114H") == "114-H")
        #expect(AcademicTerm.label(of: "99 1") == "99 -1")
        #expect(AcademicTerm.label(of: "X") == "X")
        #expect(AcademicTerm.displayParts(of: "99 1")?.year == "99 ")
        #expect(AcademicTerm.displayParts(of: "1141")?.season == "1")
        #expect(AcademicTerm.displayParts(of: "991") == nil)
    }
}

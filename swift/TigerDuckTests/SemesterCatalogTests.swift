import Foundation
import Testing
@testable import TigerDuck

struct SemesterCatalogTests {

    /// Trimmed capture of `querycourse/api/semestersinfo`, reordered so the
    /// newest published term is *not* the one 選課 is open for — that is the
    /// mid-semester shape (spring 選課 opens while fall is still in session)
    /// and the case a `list.first` shortcut would silently get wrong.
    private static let payload = Data("""
    [
      {"Semester":"1152","EngSemester":"2027 Spring","Static":false,"LoginEnable":false,
       "ShowRemind":false,"CurrentSemester":true},
      {"Semester":"1151","EngSemester":"2026 Fall","Static":false,"LoginEnable":true,
       "ShowRemind":false,"CurrentSemester":true},
      {"Semester":"114H","EngSemester":"2026 Summer","Static":false,"LoginEnable":false,
       "ShowRemind":false,"CurrentSemester":true},
      {"Semester":"1142","EngSemester":"2026 Spring","Static":false,"LoginEnable":false,
       "ShowRemind":false,"CurrentSemester":true}
    ]
    """.utf8)

    @Test("Decodes the catalogue newest-first, summer terms included")
    func decodesCatalogue() throws {
        let list = try SemesterCatalog.decodeSemesters(Self.payload)
        #expect(list.map(\.Semester) == ["1152", "1151", "114H", "1142"])
    }

    @Test("Open term comes from LoginEnable, not from list position")
    func picksOpenTermByFlag() throws {
        let list = try SemesterCatalog.decodeSemesters(Self.payload)
        #expect(SemesterCatalog.openTerm(in: list) == "1151")
    }

    @Test("A stored pick wins over the newest published term")
    func storedPickWins() {
        #expect(SemesterCatalog.selectedSemester(storedPick: "1132") == "1132")
    }

    @Test("Picker reaches back to the admission term, summer terms included")
    func reachesAdmissionTerm() {
        let catalogue = ["1151", "114H", "1142", "1141", "113H", "1132", "1131", "112H", "1122"]
        #expect(SemesterCatalog.terms(from: catalogue, admissionYear: 113)
            == ["1151", "114H", "1142", "1141", "113H", "1132", "1131"])
    }

    @Test("Unknown student id keeps the fixed depth")
    func fixedDepthWithoutId() {
        let catalogue = ["1151", "114H", "1142", "1141", "113H", "1132", "1131", "112H"]
        #expect(SemesterCatalog.terms(from: catalogue, admissionYear: nil).count == 6)
    }

    @Test("Admission year is the three digits after the degree letter")
    func parsesAdmissionYear() {
        #expect(SemesterCatalog.admissionYear(studentId: "B11315000") == 113)
        #expect(SemesterCatalog.admissionYear(studentId: "M11000001") == 110)
        #expect(SemesterCatalog.admissionYear(studentId: "abc") == nil)
        #expect(SemesterCatalog.admissionYear(studentId: nil) == nil)
    }

    @Test("No open term yields nil so the last known value is kept")
    func toleratesNoOpenTerm() throws {
        let closed = Data("""
        [{"Semester":"1151","EngSemester":"2026 Fall","Static":false,"LoginEnable":false,
          "ShowRemind":false,"CurrentSemester":true}]
        """.utf8)
        let list = try SemesterCatalog.decodeSemesters(closed)
        #expect(SemesterCatalog.openTerm(in: list) == nil)
    }
}

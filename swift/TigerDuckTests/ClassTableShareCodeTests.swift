import Foundation
import Testing
@testable import TigerDuck

struct ClassTableShareCodeTests {
    private typealias Term = ClassTableShareCode.Term

    private static let october = Date(timeIntervalSince1970: 1_791_871_500)
    private static let february = Date(timeIntervalSince1970: 1_771_551_000)

    private static let oneTerm = "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151."
        + "OMHDMNBQGQYDAMGUOGDLFDDULROWCYV6RYYFMACMBQAA.E2YUDIQ"
    private static let storedBlock = "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151."
        + "AEYQBTX7INJTCMBRGAYDAMJMINJTCMBRGAYDAMRMIVCTCMBRGAYDAMJMJVATCMBRGAYDAMJMKBCTCMBRGAYDAMI.Y4XVOOA"
    private static let severalTerms = "HTTPS://TIGERDUCK.APP/T/1.M11300002.202602200930.1151-114H-1142."
        + "GN3A4NRUGA2DAMBQ2KA3CDDV3RO2CLDLL5D2RLBVJTLFRR6VCWTMGHOOBKALCAA.XSAWPTA"

    private static let oneTermCode = ClassTableShareCode(
        format: .tigerDuck, studentId: "B11300001", sharedAt: october,
        terms: [Term(semester: "1151", courseNos: ["CS1010001", "CS1010002", "EE1010001", "MA1010001", "PE1010001"])]
    )

    @Test("one term comes back as it went in, in QR alphanumeric characters only")
    func oneTermRoundTrip() throws {
        let code = try #require(ClassTableShareCode.encode(
            studentId: "b11300001", sharedAt: Self.october.addingTimeInterval(42),
            terms: [Term(semester: "1151", courseNos: ["PE1010001", "CS1010002", "MA1010001", "CS1010001", "EE1010001", "CS1010002"])]
        ))

        #expect(code.allSatisfy { "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".contains($0) })
        #expect(code.hasPrefix("HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151."))
        #expect(try ClassTableShareCode.decode(code) == Self.oneTermCode)
    }

    @Test("several terms keep their order, and a term left without valid courses is not written")
    func severalTermsRoundTrip() throws {
        let code = try #require(ClassTableShareCode.encode(
            studentId: "M11300002", sharedAt: Self.february,
            terms: [
                Term(semester: "1151", courseNos: ["GE1010001", "3CS1010002", "CS1010001", "NOT-A-CODE"]),
                Term(semester: "1152", courseNos: ["CS101"]),
                Term(semester: "114H", courseNos: ["MA1010002"]),
                Term(semester: "1142", courseNos: ["PE1010002", "EE1010002", "GE1010002", "CS1010003"]),
            ]
        ))

        let decoded = try ClassTableShareCode.decode(code)
        #expect(decoded.studentId == "M11300002")
        #expect(decoded.sharedAt == Self.february)
        #expect(decoded.terms == [
            Term(semester: "1151", courseNos: ["3CS1010002", "CS1010001", "GE1010001"]),
            Term(semester: "114H", courseNos: ["MA1010002"]),
            Term(semester: "1142", courseNos: ["CS1010003", "EE1010002", "GE1010002", "PE1010002"]),
        ])
    }

    @Test("courses taken at NTU or NTNU are shared and read back, in either code")
    func coursesOfOtherSchools() throws {
        let code = try #require(ClassTableShareCode.encode(
            studentId: "B11300001", sharedAt: Self.october,
            terms: [Term(semester: "1151", courseNos: ["CS1010001", "3T1010004", "3N1010003"])]
        ))

        #expect(try ClassTableShareCode.decode(code).terms == [
            Term(semester: "1151", courseNos: ["3N1010003", "3T1010004", "CS1010001"]),
        ])
        #expect(try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT11151B113000013N1010003-CS1010001").terms == [
            Term(semester: "1151", courseNos: ["3N1010003", "CS1010001"]),
        ])
    }

    @Test("nothing to share writes no code")
    func nothingToShare() {
        #expect(ClassTableShareCode.encode(studentId: "B11300001", sharedAt: Self.october, terms: []) == nil)
        #expect(ClassTableShareCode.encode(
            studentId: "B11300001", sharedAt: Self.october, terms: [Term(semester: "1151", courseNos: ["CS101"])]
        ) == nil)
        #expect(ClassTableShareCode.encode(
            studentId: "B113.0001", sharedAt: Self.october, terms: [Term(semester: "1151", courseNos: ["CS1010001"])]
        ) == nil)
    }

    @Test("the fixed vectors decode, from another encoder too")
    func fixedVectors() throws {
        #expect(try ClassTableShareCode.decode(Self.oneTerm) == Self.oneTermCode)
        #expect(try ClassTableShareCode.decode(Self.storedBlock) == Self.oneTermCode)
        #expect(try ClassTableShareCode.decode(" \(Self.oneTerm.lowercased())\n") == Self.oneTermCode)
        #expect(try ClassTableShareCode.decode(Self.severalTerms) == ClassTableShareCode(
            format: .tigerDuck, studentId: "M11300002", sharedAt: Self.february,
            terms: [
                Term(semester: "1151", courseNos: ["3CS1010002", "CS1010001", "GE1010001"]),
                Term(semester: "114H", courseNos: ["MA1010002"]),
                Term(semester: "1142", courseNos: ["CS1010003", "EE1010002", "GE1010002", "PE1010002"]),
            ]
        ))
    }

    @Test("changing any one character after the version fails the checksum", arguments: [oneTerm, severalTerms])
    func changedCharacterFailsChecksum(vector: String) {
        let characters = Array(vector)
        let fieldsStart = ClassTableShareCode.prefix.count + 2
        for index in fieldsStart..<characters.count where characters[index].isLetter || characters[index].isNumber {
            var changed = characters
            let original = characters[index]
            changed[index] = original.isLetter ? (original == "A" ? "B" : "A") : (original == "2" ? "3" : "2")
            #expect(throws: ClassTableShareCodeError.checksumMismatch, "index \(index)") {
                try ClassTableShareCode.decode(String(changed))
            }
        }
    }

    @Test("a course code outside NTUST's shape is refused, though the checksum matches")
    func badCourseCode() {
        #expect(throws: ClassTableShareCodeError.invalidCourseCode("CS10100")) {
            try ClassTableShareCode.decode(
                "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLAAA.5GDOVTY"
            )
        }
        #expect(throws: ClassTableShareCodeError.invalidCourseCode("123456789")) {
            try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001123456789.12")
        }
    }

    @Test("a code with a sound checksum but a broken layout is malformed", arguments: [
        "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151-1151.OMHDMNBQGQYDAMFUO2DLFDAA.4HFLDLQ",
        "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151-1142.OMHDMNBQGQYDAMAEAA.XT6KUZI",
        "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151-1142.OMHDMNBQGQYDAMFUAYAA.5A4SDJY",
        "HTTPS://TIGERDUCK.APP/T/1.B11300001.202602300930.1151.OMHDMNBQGQYDAMAEAA.MASPS5I",
        "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLCAA.5IBD5II",
        "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151",
        "HTTPS://TIGERDUCK.APP/T/V1.B11300001",
    ])
    func malformed(vector: String) {
        #expect(throws: ClassTableShareCodeError.malformed) { try ClassTableShareCode.decode(vector) }
    }

    @Test("other QR codes and newer versions are told apart from damaged codes")
    func unknownPrefixAndVersion() {
        for other in ["https://example.com/T/1.B11300001", "WIFI:S:home;T:WPA;P:secret;;", "", "HTTPS://TIGERDUCK.APP/X/1."] {
            #expect(throws: ClassTableShareCodeError.unknownPrefix) { try ClassTableShareCode.decode(other) }
        }
        for newer in [
            "HTTPS://TIGERDUCK.APP/T/2.B11300001.202610131405.1151.OMHDMNBQGQYDAMAEAA.O6Y5T6Y",
            "HTTPS://TIGERDUCK.APP/T/12",
            "HTTPS://NTUST-TAT.WEB.APP/S/TAT31151B11300001CS1010001",
        ] {
            #expect(throws: ClassTableShareCodeError.unknownVersion) { try ClassTableShareCode.decode(newer) }
        }
    }

    @Test("a TAT version 2 code keeps its term, student ID and course codes and drops the class times")
    func tatVersion2() throws {
        let decoded = try ClassTableShareCode.decode(
            "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001.267-EE1010002.13.5N-MA1010003"
        )
        #expect(decoded == ClassTableShareCode(
            format: .tat2, studentId: "B11300001", sharedAt: nil,
            terms: [Term(semester: "1151", courseNos: ["CS1010001", "EE1010002", "MA1010003"])]
        ))

        let padded = try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT2114HB113     GE1010001.6AB")
        #expect(padded.studentId == "B113")
        #expect(padded.terms == [Term(semester: "114H", courseNos: ["GE1010001"])])

        let blank = try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT21151         ")
        #expect(blank.studentId == nil)
        #expect(blank.terms == [Term(semester: "1151", courseNos: [])])
    }

    @Test("a TAT version 1 code, which has no class times, decodes")
    func tatVersion1() throws {
        #expect(try ClassTableShareCode.decode(
            "HTTPS://NTUST-TAT.WEB.APP/S/TAT11142B11300002CS1010004-PE1010005"
        ) == ClassTableShareCode(
            format: .tat1, studentId: "B11300002", sharedAt: nil,
            terms: [Term(semester: "1142", courseNos: ["CS1010004", "PE1010005"])]
        ))
    }

    @Test("a TAT code with a weekday, period or course code length TAT never writes is malformed", arguments: [
        "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001.83",
        "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001.3Z",
        "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001.3",
        "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B113000013CS1010001",
        "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001-",
        "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001CS1010001-CS1010001",
        "HTTPS://NTUST-TAT.WEB.APP/S/TAT2115",
        "HTTPS://NTUST-TAT.WEB.APP/S/XYZ21151B11300001CS1010001",
    ])
    func tatMalformed(vector: String) {
        #expect(throws: ClassTableShareCodeError.malformed) { try ClassTableShareCode.decode(vector) }
    }

    @MainActor
    @Test("the TAT encoder writes each course's weekdays and periods in TAT's letters, and the code decodes")
    func tatEncoderRoundTrip() throws {
        let courses = [
            SDCourse(courseNo: "CS1010001", courseName: "A", schedule: [2: ["8", "7"]]),
            SDCourse(courseNo: "EE1010002", courseName: "B", schedule: [5: ["5"], 1: ["3"]]),
            SDCourse(courseNo: "GE1010003", courseName: "C", schedule: [3: ["10", "A", "9"], 6: ["D"]]),
            SDCourse(courseNo: "MA1010004", courseName: "D"),
            SDCourse(courseNo: "3CS1010005", courseName: "E", schedule: [1: ["1"]]),
            SDCourse(courseNo: "CS1010001", courseName: "A again", schedule: [4: ["1"]]),
            SDCourse(courseNo: "PE1010006", courseName: "F", schedule: [8: ["1"], 4: ["X"]]),
        ]

        let code = try #require(ClassTableShareCode.encodeTAT(studentId: "B11300001", semester: "1151", courses: courses))

        #expect(code == "HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001"
            + "CS1010001.267-EE1010002.13.5N-GE1010003.389A.6D-MA1010004-PE1010006")
        #expect(try ClassTableShareCode.decode(code) == ClassTableShareCode(
            format: .tat2, studentId: "B11300001", sharedAt: nil,
            terms: [Term(semester: "1151", courseNos: ["CS1010001", "EE1010002", "GE1010003", "MA1010004", "PE1010006"])]
        ))
        let short = try #require(ClassTableShareCode.encodeTAT(studentId: "b113", semester: "1151", courses: courses))
        #expect(try ClassTableShareCode.decode(short).studentId == "B113")
        #expect(ClassTableShareCode.encodeTAT(studentId: "B113000011", semester: "1151", courses: courses) == nil)
    }
}

import Foundation
import Testing
@testable import TigerDuck

struct ClassTableShareCodeTests {
    private typealias Term = ClassTableShareCode.Term

    private final class Token {}

    private struct Vector {
        var name: String
        var studentId = ""
        var sharedAt = Date.distantPast
        var terms: [Term] = []
        var code = ""
    }

    private static let taipei: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
        return calendar
    }()

    private static func taipeiDate(_ text: Substring) -> Date? {
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 5 else { return nil }
        return taipei.date(from: DateComponents(
            year: numbers[0], month: numbers[1], day: numbers[2], hour: numbers[3], minute: numbers[4]
        ))
    }

    /// The vectors in `ClassTableShareCodeVectors.txt`, the file the Android app's tests pin too:
    /// the valid codes with their tables, and the refused codes after the description of each.
    private static func vectors() throws -> (valid: [Vector], refused: [(description: String, code: String)]) {
        let url = try #require(Bundle(for: Token.self).url(forResource: "ClassTableShareCodeVectors", withExtension: "txt"))
        var valid: [Vector] = []
        var refused: [(String, String)] = []
        var description = ""
        var isRefused = false
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n").dropFirst() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == "REFUSED" {
                isRefused = true
            } else if isRefused {
                if text.hasPrefix("HTTPS://") { refused.append((description, text)) } else { description = text }
            } else if text.allSatisfy({ $0.isUppercase || $0 == "_" }) {
                valid.append(Vector(name: text))
            } else if text.hasPrefix("student ") {
                let parts = text.dropFirst("student ".count).split(separator: ", shared ")
                valid[valid.count - 1].studentId = String(parts[0])
                valid[valid.count - 1].sharedAt = try #require(taipeiDate(parts[1]))
            } else if text.hasPrefix("HTTPS://") {
                valid[valid.count - 1].code = text
            } else {
                let parts = text.split(separator: ": ")
                valid[valid.count - 1].terms.append(Term(
                    semester: String(parts[0]), courseNos: parts[1].split(separator: " ").map(String.init)
                ))
            }
        }
        return (valid, refused)
    }

    private static let october = Date(timeIntervalSince1970: 1_791_871_500)
    private static let oneTerm = [Term(semester: "1151", courseNos: ["CS1010001", "MA1010001"])]

    @Test("every shared test code decodes to its table, and the encoder writes it character for character")
    func sharedVectors() throws {
        let vectors = try Self.vectors().valid
        #expect(vectors.map(\.name) == [
            "ONE_TERM", "SEVERAL_TERMS_WITH_SUMMER", "LONGEST_STUDENT_ID", "UNUSUAL_COURSE_CODES",
            "EXPLICIT_TERMS", "LARGEST_ALL_TERMS",
        ])
        for vector in vectors {
            let decoded = try ClassTableShareCode.decode(vector.code)
            #expect(decoded == ClassTableShareCode(
                format: .tigerDuck, studentId: vector.studentId, sharedAt: vector.sharedAt, terms: vector.terms
            ), "\(vector.name)")
            #expect(ClassTableShareCode.encode(
                studentId: vector.studentId, sharedAt: vector.sharedAt, terms: vector.terms
            ) == vector.code, "\(vector.name)")
        }
    }

    @Test("the shared refused codes are told apart: a newer version or type, a bad checksum, a malformed version")
    func sharedRefusedVectors() throws {
        let refused = try Self.vectors().refused
        #expect(refused.count == 4)
        for (description, code) in refused {
            let expected: ClassTableShareCodeError? = if description.hasPrefix("Newer version") {
                .unknownVersion
            } else if description.hasPrefix("Checksum mismatch") {
                .checksumMismatch
            } else if description.hasPrefix("Unknown type") {
                .unknownType
            } else if description.hasPrefix("Version that is not a digit") {
                .malformed
            } else {
                nil
            }
            let error = try #require(expected, "\(description)")
            #expect(throws: error, "\(description)") { try ClassTableShareCode.decode(code) }
        }
    }

    @Test("a code reads the same in lower case and with whitespace around it, and in QR alphanumeric characters only")
    func caseAndWhitespace() throws {
        let code = try #require(ClassTableShareCode.encode(studentId: "b11300001", sharedAt: Self.october, terms: Self.oneTerm))

        #expect(code.hasPrefix("HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1"))
        #expect(code.allSatisfy { "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ:/.".contains($0) })
        let decoded = try ClassTableShareCode.decode(code)
        #expect(decoded.studentId == "B11300001")
        #expect(try ClassTableShareCode.decode(" \(code.lowercased())\n") == decoded)
        #expect(try ClassTableShareCode.decode(code.replacingOccurrences(of: "HTTPS://SHARE", with: "https://share")) == decoded)
    }

    @Test("several terms come back newest first, each sorted, and a term left without valid courses is not written")
    func severalTermsRoundTrip() throws {
        let code = try #require(ClassTableShareCode.encode(
            studentId: "M11300002", sharedAt: Self.october,
            terms: [
                Term(semester: "1142", courseNos: ["PE1010002", "EE1010002", "GE1010002", "CS1010003"]),
                Term(semester: "1151", courseNos: ["GE1010001", "3CS1010002", "CS1010001", "NOT-A-CODE", "3N1010003"]),
                Term(semester: "1152", courseNos: ["CS101"]),
                Term(semester: "114H", courseNos: ["MA1010002", "MA1010002"]),
            ]
        ))

        let decoded = try ClassTableShareCode.decode(code)
        #expect(decoded.studentId == "M11300002")
        #expect(decoded.sharedAt == Self.october)
        #expect(decoded.terms == [
            Term(semester: "1151", courseNos: ["3CS1010002", "3N1010003", "CS1010001", "GE1010001"]),
            Term(semester: "114H", courseNos: ["MA1010002"]),
            Term(semester: "1142", courseNos: ["CS1010003", "EE1010002", "GE1010002", "PE1010002"]),
        ])
    }

    @Test("a table past the layout's limits writes no code, and sharing every term keeps the newest 24")
    func limits() throws {
        func code(id: String = "B11300001", at: Date = Self.october, terms: [Term] = Self.oneTerm) -> String? {
            ClassTableShareCode.encode(studentId: id, sharedAt: at, terms: terms)
        }

        #expect(code(terms: []) == nil)
        #expect(code(terms: [Term(semester: "1151", courseNos: ["CS101"])]) == nil)
        #expect(code(id: "B113.0001") == nil)
        #expect(code(id: String(repeating: "A", count: 16)) != nil)
        #expect(code(id: String(repeating: "A", count: 17)) == nil)
        #expect(code(at: Date(timeIntervalSince1970: 1_704_038_340)) == nil, "a minute before 2024 in Taipei")
        #expect(code(at: Date(timeIntervalSince1970: 1_704_038_400)) != nil)
        let crowded = (0..<65).map { "CS10" + String(format: "%05ld", 10_001 + $0) }
        #expect(code(terms: [Term(semester: "1151", courseNos: crowded)]) == nil)
        #expect(code(terms: [Term(semester: "1151", courseNos: Array(crowded.prefix(64)))]) != nil)

        let terms = (0..<26).map { Term(semester: String(format: "%03ld1", 90 + $0), courseNos: ["CS1010001"]) }
        let decoded = try ClassTableShareCode.decode(try #require(code(terms: terms)))
        #expect(decoded.terms.map(\.semester) == (0..<24).map { String(format: "%03ld1", 115 - $0) })
    }

    @Test("changing any one character after the version, or cutting the code short, is refused")
    func damagedCodes() throws {
        let vector = try #require(try Self.vectors().valid.first).code
        let characters = Array(vector)
        let payloadStart = ClassTableShareCode.prefix.count + 1
        for index in payloadStart..<characters.count {
            var changed = characters
            changed[index] = characters[index] == "A" ? "B" : "A"
            #expect(throws: (any Error).self, "index \(index)") { try ClassTableShareCode.decode(String(changed)) }
        }
        for length in payloadStart..<characters.count {
            #expect(throws: (any Error).self, "length \(length)") {
                try ClassTableShareCode.decode(String(characters.prefix(length)))
            }
        }
    }

    @Test("a code with a sound checksum that an encoder would have written otherwise is malformed", arguments: [
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1M9M7VS1JS2NLSB5V0HXU1KSG0A",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/10NUAQSJB234P2JM5FK0LKZ9OK2XM74",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1F9FT7Y1JS2MW09283G8Y4DMW4SKTU8",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1M4Z51AJB234O09283GA15X5HB8LS",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1BGQSCA1JS2MW09283GA20K079G",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1CND0R41JS2MW09283GM9UJNMG",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1CJ0M931JS2MW09283GA1GT3L",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/1550UEN1JS2MI4G3LYRVI9TUO034DHS",
    ])
    func notCanonical(vector: String) {
        // In order: explicit terms the regular layout holds, an NTUST student ID written as any
        // other, head 3N with tail G115701, tails out of order, a tail in a later shape, a known
        // head written as unknown, padding that is not zero, and a term left without a head.
        #expect(throws: ClassTableShareCodeError.malformed) { try ClassTableShareCode.decode(vector) }
    }

    @Test("the share host alone, or a path that is not a type and a slash, is malformed", arguments: [
        "HTTPS://SHARE.TIGERDUCK.APP",
        "https://share.tigerduck.app/",
        "HTTPS://SHARE.TIGERDUCK.APP?FROM=MAIL",
        "HTTPS://SHARE.TIGERDUCK.APP#TOP",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/HELLO",
        "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/0ABC",
        "HTTPS://SHARE.TIGERDUCK.APP/FRIEND",
        "HTTPS://SHARE.TIGERDUCK.APP//",
        "HTTPS://SHARE.TIGERDUCK.APP//CLASSTABLE/1",
        "HTTPS://SHARE.TIGERDUCK.APP/FRI-END/1",
    ])
    func malformedOnShareHost(vector: String) {
        #expect(throws: ClassTableShareCodeError.malformed) { try ClassTableShareCode.decode(vector) }
    }

    @Test("another type on the share host, or a newer version, needs a newer app")
    func newerTypeOrVersion() {
        for code in ["HTTPS://SHARE.TIGERDUCK.APP/FRIEND/1ABC", "https://share.tigerduck.app/friend/", "HTTPS://SHARE.TIGERDUCK.APP/T2/X"] {
            #expect(throws: ClassTableShareCodeError.unknownType, "\(code)") { try ClassTableShareCode.decode(code) }
        }
        for code in ["HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/9", "HTTPS://NTUST-TAT.WEB.APP/S/TAT31151B11300001CS1010001"] {
            #expect(throws: ClassTableShareCodeError.unknownVersion, "\(code)") { try ClassTableShareCode.decode(code) }
        }
    }

    private static let packed = "1KNTO5SJB234O09283J89PYINHMLGU86XQH3K2WVREW0CHIZS78"
    private static let tatBody = "TAT21151B11300001CS1010001.267-EE1010002.13.5N-MA1010003"

    @Test("our link and TAT's read in any case, with http, https or no scheme, a query, fragment or trailing slash, on any host, or as the code alone")
    func lenientForms() throws {
        let ours = try ClassTableShareCode.decode(ClassTableShareCode.prefix + Self.packed)
        let lower = Self.packed.lowercased()
        for text in [
            "http://share.tigerduck.app/classtable/" + lower,
            "share.tigerduck.app/CLASSTABLE/" + Self.packed,
            "HTTPS://SHARE.TIGERDUCK.APP/CLASSTABLE/" + Self.packed + "/",
            "https://share.tigerduck.app/classtable/" + lower + "?fbclid=IwAR0abc",
            "https://share.tigerduck.app/CLASSTABLE/" + Self.packed + "/?from=mail#top",
            "https://share.tigerduck.app/CLASSTABLE/" + Self.packed + "#",
            "https://whatever.example.tld/" + Self.packed,
            "https://whatever.example.tld/CLASSTABLE/" + lower + "/",
            "whatever.example.tld/classtable/" + Self.packed + "?x=1",
            "HTTPS://TIGERDUCK.APP/CLASSTABLE/" + Self.packed,
            "HTTPS://SHARE.TIGERDUCK.APP.EXAMPLE.COM/CLASSTABLE/" + Self.packed,
            "HTTPS://SHARE.TIGERDUCK.APP@EXAMPLE.COM/CLASSTABLE/" + Self.packed,
            "HTTPS://SHARE.TIGERDUCK.APP:443/CLASSTABLE/" + Self.packed,
            Self.packed,
            " \n" + lower + "\t",
        ] {
            #expect(try ClassTableShareCode.decode(text) == ours, "\(text)")
        }

        let tat = try ClassTableShareCode.decode(ClassTableShareCode.tatPrefix + Self.tatBody)
        for text in [
            "https://ntust-tat.web.app/s/" + Self.tatBody.lowercased(),
            "http://ntust-tat.web.app/s/" + Self.tatBody,
            "ntust-tat.web.app/S/" + Self.tatBody + "/",
            "https://ntust-tat.web.app/s/" + Self.tatBody + "?openExternalBrowser=1",
            "https://whatever.example.tld/S/" + Self.tatBody,
            "https://whatever.example.tld/" + Self.tatBody.lowercased(),
            Self.tatBody,
            " " + Self.tatBody.lowercased() + "\n",
        ] {
            #expect(try ClassTableShareCode.decode(text) == tat, "\(text)")
        }

        let padded = try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT2114HB113     GE1010001.6AB")
        for text in [
            "https://ntust-tat.web.app/s/TAT2114HB113%20%20%20%20%20GE1010001.6AB",
            "https://whatever.example.tld/s/tat2114hb113%20%20%20%20%20ge1010001.6ab",
            "TAT2114HB113%20%20%20%20%20GE1010001.6AB",
        ] {
            #expect(try ClassTableShareCode.decode(text) == padded, "\(text)")
        }
    }

    @Test("our host and TAT's keep their errors in every form they read in")
    func lenientFormsKeepErrors() {
        let cases: [(String, ClassTableShareCodeError)] = [
            ("share.tigerduck.app/friend/1abc", .unknownType),
            ("http://share.tigerduck.app/friend/", .unknownType),
            ("http://share.tigerduck.app/classtable/9", .unknownVersion),
            ("share.tigerduck.app/CLASSTABLE/1KNTO5SJB234O09283J89PYINHMLGU86XQH3K2WVREW0CHIZA78", .checksumMismatch),
            ("https://share.tigerduck.app/classtable/hello?x=1", .malformed),
            ("http://share.tigerduck.app", .malformed),
            ("http://ntust-tat.web.app/s/TAT2115", .malformed),
            ("ntust-tat.web.app/s/tat31151b11300001cs1010001", .unknownVersion),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try ClassTableShareCode.decode(text) }
        }
    }

    @Test("other QR codes, broken codes off our host and TAT's, and the old tigerduck.app/T/ prefix are not share codes", arguments: [
        "https://example.com/T/1.B11300001",
        "WIFI:S:home;T:WPA;P:secret;;",
        "",
        "HTTPS://TIGERDUCK.APP/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLFDDULROWCYV6RYYFMACMBQAA.E2YUDIQ",
        "https://example.com/",
        "https://example.com/menu",
        "hello world",
        "100% sure",
        "12345",
        "1ABC",
        "https://example.com/1ABC",
        "https://example.com/CLASSTABLE/1KNTO5SJB234O09283J89PYINHMLGU86XQH3K2WVREW0CHIZA78",
        "https://example.com/S/TAT2115",
        "TAT2115",
        "TATTOO",
        "TAT31151B11300001CS1010001",
        "SHARE.TIGERDUCK.APP.EXAMPLE.COM/FRIEND/1ABC",
        "ftp://share.tigerduck.app/friend/1abc",
        "https://ntust-tat.web.app/",
    ])
    func notShareCodes(text: String) {
        #expect(throws: ClassTableShareCodeError.unknownPrefix) { try ClassTableShareCode.decode(text) }
    }

    @Test("a TAT code with a course code outside NTUST's shape is refused as such")
    func badTATCourseCode() throws {
        #expect(throws: ClassTableShareCodeError.invalidCourseCode("123456789")) {
            try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT21151B11300001123456789.12")
        }
        #expect(try ClassTableShareCode.decode("HTTPS://NTUST-TAT.WEB.APP/S/TAT11151B113000013N1010003-CS1010001").terms == [
            Term(semester: "1151", courseNos: ["3N1010003", "CS1010001"]),
        ])
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

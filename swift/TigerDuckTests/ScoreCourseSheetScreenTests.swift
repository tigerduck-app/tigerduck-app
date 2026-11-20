#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct ScoreCourseSheetScreenTests {
    typealias Look = ClubScreensTests.Look
    typealias Copy = CopyToastScreenTests

    static let term = "1151"
    static let termText = "115 \(String(localized: "score_semester_first"))"
    static let creditsLabel = String(localized: "course_detail_credits_label")
    static let enrollmentLabel = String(localized: "score_course_detail_enrollment_label")
    static let scheduleLabel = String(localized: "score_course_detail_schedule_label")
    static let locationLabel = String(localized: "course_detail_location_label")
    static let noRoster = String(localized: "course_detail_no_roster")

    static func grade(name: String = "資料結構與演算法", credits: Double? = 3) -> CourseGrade {
        CourseGrade(
            index: 0, term: term, code: "CS2001301", name: name, credits: credits, creditType: .normal, grade: "A+",
            status: .graded, remark: "", geDimension: nil, distanceLearning: false
        )
    }

    static func roster(instructor: String = "王大明", classroom: String = "TR-313") -> SDCourse {
        SDCourse(
            courseNo: "CS2001301", courseName: "資料結構與演算法", instructor: instructor, credits: 3, classroom: classroom,
            enrolledCount: 40, maxCount: 60, schedule: [1: ["2", "3"]], semester: term
        )
    }

    struct Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoreCourseSheetScreenTests-\(UUID().uuidString)", isDirectory: true)

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    static func sheet(_ grade: CourseGrade, roster: SDCourse?, in folder: Folder) -> ScoreCourseDetailSheet {
        let courses = CourseStore(folders: CacheFolders(root: folder.url))
        if let roster { courses.apply(.addByHand(roster, semester: term), for: testSignIn) }
        return ScoreCourseDetailSheet(course: grade, policy: Copy.policy, courses: courses)
    }

    /// The index of each label among the sheet's elements, top to bottom; nil for one it lacks.
    static func order(of labels: [String], in window: UIWindow) -> [Int?] {
        let shown = exposedAccessibilityLabels(in: window)
        return labels.map { shown.firstIndex(of: $0) }
    }

    @Test("the sheet has no navigation bar, and its header shows the course name and the term")
    func header() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            defer { folder.remove() }
            let grade = Self.grade()
            let window = try ClubScreensTests.show(Self.sheet(grade, roster: nil, in: folder), look: ClubScreensTests.looks[0], height: 874)
            defer { window.isHidden = true }

            _ = try await Copy.element(Self.termText, in: window)
            #expect(window.descendants(ofType: UINavigationBar.self).isEmpty)
            let labels = exposedAccessibilityLabels(in: window)
            #expect(Array(labels.prefix(3)) == [grade.name, Self.termText, grade.grade], "\(labels)")
            #expect(!labels.contains(grade.code))
        }
    }

    @Test("the rows follow the class table sheet's order, code and credits with or without a roster", arguments: [true, false])
    func rows(hasRoster: Bool) async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            defer { folder.remove() }
            let grade = Self.grade(credits: hasRoster ? 3 : nil)
            let sheet = Self.sheet(grade, roster: hasRoster ? Self.roster() : nil, in: folder)
            let window = try ClubScreensTests.show(sheet, look: ClubScreensTests.looks[0], height: 874)
            defer { window.isHidden = true }

            // The sheet looks the roster up once it appears, so the rows wait for what it adds.
            _ = try await Copy.element(hasRoster ? "\(Copy.instructorLabel), 王大明" : Self.noRoster, in: window)
            let code = try await Copy.element("\(Copy.codeLabel), \(grade.code)", in: window)
            #expect(code.accessibilityTraits.contains(.button))
            #expect(code.accessibilityHint == Copy.copyCode)
            let rosterRows = [
                "\(Copy.instructorLabel), 王大明", Self.enrollmentLabel, "40 / 60", "\(Self.locationLabel), TR-313",
                Self.scheduleLabel, "M2, M3",
            ]
            if hasRoster {
                let order = Self.order(of: [
                    rosterRows[0], code.accessibilityLabel ?? "", Self.creditsLabel, "3",
                ] + rosterRows[1...], in: window)
                #expect(!order.contains(nil), "\(order)")
                #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted())
                #expect(accessibilityElement(labeled: Self.noRoster, in: window) == nil)
            } else {
                let order = Self.order(of: [code.accessibilityLabel ?? "", Self.creditsLabel, "—", Self.noRoster], in: window)
                #expect(!order.contains(nil), "\(order)")
                #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted())
                #expect(Self.order(of: rosterRows, in: window).allSatisfy { $0 == nil })
            }
        }
    }

    @Test("a tap or VoiceOver's activation of the code, instructor or location row copies it and says so", arguments: [
        ("code", false), ("code", true), ("instructor", false), ("location", true),
    ])
    func copies(row: String, byVoiceOver: Bool) async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            defer { folder.remove() }
            let window = try ClubScreensTests.show(
                Self.sheet(Self.grade(), roster: Self.roster(), in: folder), look: ClubScreensTests.looks[0], height: 874
            )
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            let (label, hint, toast, copied) = switch row {
            case "code": (Copy.codeLabel, Copy.copyCode, Copy.codeCopied, "CS2001301")
            case "instructor": (Copy.instructorLabel, Copy.copyInstructor, Copy.instructorCopied, "王大明")
            default: (Self.locationLabel, Copy.copyLocation, Copy.locationCopied, "TR-313")
            }
            _ = try await Copy.element("\(Copy.instructorLabel), 王大明", in: window)
            let element = try await Copy.element("\(label), \(copied)", in: window)
            #expect(element.accessibilityTraits.contains(.button))
            #expect(element.accessibilityHint == hint)
            if byVoiceOver {
                #expect(element.accessibilityActivate())
            } else {
                try await Copy.tap(element, in: window, until: toast)
            }

            try await waitUntil { accessibilityElement(labeled: toast, in: window) != nil }
            #expect(UIPasteboard.general.string == copied)
        }
    }

    @Test("a blank instructor or location in the roster shows a dash that is no button and copies nothing")
    func blankRosterValues() async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            defer { folder.remove() }
            let sheet = Self.sheet(Self.grade(), roster: Self.roster(instructor: " ", classroom: ""), in: folder)
            let window = try ClubScreensTests.show(sheet, look: ClubScreensTests.looks[0], height: 874)
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            _ = try await Copy.element(Self.locationLabel, in: window)
            let labels = exposedAccessibilityLabels(in: window)
            let instructor = try #require(labels.firstIndex(of: Copy.instructorLabel))
            let location = try #require(labels.firstIndex(of: Self.locationLabel))
            #expect(labels[instructor + 1] == "—")
            #expect(labels[location + 1] == "—")
            let hints = exposedAccessibilityElements(in: window).compactMap(\.accessibilityHint)
            #expect(!hints.contains(Copy.copyInstructor))
            #expect(!hints.contains(Copy.copyLocation))
            #expect(UIPasteboard.general.string == "before")
        }
    }

    struct Shot: CustomTestStringConvertible {
        let width: CGFloat
        let look: Look
        let long: Int

        var testDescription: String { "\(Int(width))-\(look.testDescription)-\(long == 0 ? "zh" : "en")-names" }
    }

    static let shots = SettingsSnapshotTests.widths.flatMap { width in
        ClubScreensTests.looks.flatMap { look in [0, 1].map { Shot(width: width, look: look, long: $0) } }
    }

    @Test("the sheet with its toast up keeps the header, the rows and the toast on the phone", arguments: shots)
    func snapshot(shot: Shot) async throws {
        try await withAccessibilityAutomation {
            let folder = Folder()
            defer { folder.remove() }
            let instructor = Copy.longInstructors[shot.long]
            let sheet = Self.sheet(
                Self.grade(name: Copy.longCourseNames[shot.long]), roster: Self.roster(instructor: instructor), in: folder
            )
            let window = try ClubScreensTests.show(
                Color.clear.sheet(isPresented: .constant(true)) {
                    sheet.presentationDetents([.medium, .large], selection: .constant(.large))
                },
                look: shot.look, width: shot.width, height: 874
            )
            defer {
                window.rootViewController?.dismiss(animated: false)
                window.isHidden = true
            }
            let row = try await Copy.element("\(Copy.instructorLabel), \(instructor)", in: window)
            try await Task.sleep(for: .milliseconds(600))
            #expect(row.accessibilityActivate())
            let shown = try await Copy.element(Copy.instructorCopied, in: window)
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "score-course-\(shot.testDescription)-\(Copy.language)-ios\(UIDevice.current.systemVersion)")

            let screen = window.convert(window.bounds, to: window.screen.coordinateSpace)
            #expect(screen.contains(shown.accessibilityFrame), "toast at \(shown.accessibilityFrame)")
            let rowFrame = row.accessibilityFrame
            #expect(rowFrame.minX >= screen.minX && rowFrame.maxX <= screen.maxX, "row at \(rowFrame)")
        }
    }
}
#endif

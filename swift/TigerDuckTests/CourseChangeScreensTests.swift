#if os(iOS)
import Defaults
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct CourseChangeScreensTests {
    struct Look: CustomTestStringConvertible {
        let style: UIUserInterfaceStyle
        let width: CGFloat

        var club: ClubScreensTests.Look { ClubScreensTests.Look(style: style, textSize: .large) }
        var testDescription: String { "\(style == .dark ? "dark" : "light")-\(Int(width))" }
    }

    static let looks = [375, 820].flatMap { width in
        [UIUserInterfaceStyle.light, .dark].map { Look(style: $0, width: CGFloat(width)) }
    }

    static let exam = ["note_zh": "期中考", "note_en": "Midterm exam"]
    static let longName = "人工智慧與機器學習導論：從理論到實務應用"

    static func courses(_ term: String) -> [SDCourse] {
        [
            SDCourse(courseNo: "CS3001301", courseName: "作業系統", classroom: "TR-313", schedule: [1: ["2", "3", "4"], 3: ["2", "3"]], semester: term),
            SDCourse(courseNo: "CS3002301", courseName: "計算機網路", classroom: "IB-201", schedule: [2: ["6", "7"]], semester: term),
            SDCourse(courseNo: "GE3005301", courseName: longName, classroom: "RB-105", schedule: [4: ["3", "4"]], semester: term),
            SDCourse(courseNo: "EE3004301", courseName: "電子學", classroom: "EE-404", schedule: [5: ["6", "7"]], semester: term),
            SDCourse(courseNo: "CS3007301", courseName: "編譯器", classroom: "TR-411", schedule: [3: ["6", "7"]], semester: term),
            SDCourse(courseNo: "CS3008301", courseName: "資料庫", classroom: "TR-412", schedule: [3: ["7", "8"]], semester: term),
            SDCourse(courseNo: "EE3009301", courseName: "訊號與系統", classroom: "EE-101", schedule: [4: ["7", "8"]], semester: term),
            SDCourse(courseNo: "EE3010301", courseName: "控制工程", classroom: "EE-102", schedule: [4: ["8", "9"]], semester: term),
            SDCourse(courseNo: "EE3011301", courseName: "通訊原理", classroom: "EE-103", schedule: [4: ["7", "8", "9"]], semester: term),
        ]
    }

    @Test(
        "this week's class table underlines an assessment, in a conflict too, but not a cancelled one, and shows an online class in its room's place",
        arguments: looks
    )
    func classTable(look: Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let signIn = testSignIn
                let storedPick = Defaults[.classTableSelectedSemester, for: signIn]
                let storedFeed = Defaults[.courseChangesCache]
                let showedRooms = Defaults[.showClassroomInClassTable]
                defer {
                    Defaults[.classTableSelectedSemester, for: signIn] = storedPick
                    Defaults[.courseChangesCache] = storedFeed
                    Defaults[.showClassroomInClassTable] = showedRooms
                }
                let root = FileManager.default.temporaryDirectory.appending(path: "CourseChangeScreens-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: root) }
                let store = CourseStore(folders: CacheFolders(root: root))
                let people = ImportedClassTableStore(fileURL: root.appending(path: "imported.json"), signedInStudentId: { nil })
                let model = ClassTableViewModel(courses: store, importedTables: people)
                let term = SchoolTerms.current
                let now = AppClock.now()
                @MainActor func day(_ weekday: Int) -> [String] { [TaipeiTime.dayKey(for: ClassTableViewModel.nextDate(onWeekday: weekday, from: now))] }
                Defaults[.showClassroomInClassTable] = true
                Defaults[.courseChangesCache] = CourseChangesTests.feed([
                    CourseChangesTests.row(1, "assessment", course: "CS3001301", days: day(1), values: Self.exam),
                    CourseChangesTests.row(2, "online", course: "CS3002301", days: day(2)),
                    CourseChangesTests.row(3, "assessment", course: "GE3005301", days: day(4), values: Self.exam),
                    CourseChangesTests.row(4, "assessment", course: "EE3004301", days: day(5), values: Self.exam),
                    CourseChangesTests.row(5, "cancelled", course: "EE3004301", days: day(5)),
                    CourseChangesTests.row(6, "assessment", course: "CS3007301", days: day(3), values: Self.exam),
                    CourseChangesTests.row(7, "assessment", course: "EE3009301", days: day(4), values: Self.exam),
                ])
                for course in Self.courses(term) { store.apply(.addByHand(course, semester: term), for: testSignIn) }
                SchoolAccountKeys.pickSemester(term, for: signIn)
                model.pickSemester(term, for: signIn)
                model.reloadFromCache()
                #expect(model.showsThisWeek)

                let table = VStack { TimetableGridView(viewModel: model); Spacer(minLength: 0) }
                    .padding(.top, 60)
                    .environment(AppPreferences())
                let window = try ClubScreensTests.show(table, look: look.club, width: look.width, height: 760)
                defer { window.isHidden = true }
                let assessment = String(localized: "course_change_assessment")
                try await waitUntil { exposedAccessibilityLabels(in: window).contains { $0.contains("作業系統, \(assessment)") } }
                try await Task.sleep(for: .milliseconds(400))
                window.saveSnapshot(as: "class-table-\(look.testDescription)")

                let labels = exposedAccessibilityLabels(in: window)
                #expect(labels.filter { $0.contains("作業系統") }.count == 2)
                #expect(labels.filter { $0.contains("作業系統, \(assessment)") }.count == 1)
                #expect(labels.contains { $0.contains("\(Self.longName), \(assessment)") })
                #expect(labels.contains { $0.contains("計算機網路, \(String(localized: "course_change_online"))") })
                let cancelled = try #require(labels.first { $0.contains("電子學") })
                #expect(cancelled.contains(String(localized: "course_card_cancelled")) && !cancelled.contains(assessment))
                let pair = try #require(labels.first { $0.contains("編譯器") })
                #expect(pair.contains("編譯器, \(assessment)") && pair.contains("資料庫") && !pair.contains("資料庫, \(assessment)"))
                #expect(labels.contains { $0.contains("訊號與系統, \(assessment)") })
                #expect(!labels.contains { $0.contains("控制工程, \(assessment)") || $0.contains("通訊原理, \(assessment)") })
            }
        }
    }

    @Test("Home's course card underlines an assessment and shows an online class in its room's place", arguments: [looks[0], looks[1]])
    func courseCard(look: Look) async throws {
        try await withAccessibilityAutomation {
            let thursday = try #require(TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
            let courses = [
                SDCourse(courseNo: "CS3001301", courseName: "作業系統", instructor: "王大明", classroom: "TR-313", schedule: [4: ["2", "3", "4"]]),
                SDCourse(courseNo: "CS3002301", courseName: "計算機網路", instructor: "林小華", classroom: "IB-201", schedule: [4: ["6", "7"]]),
            ]
            let changes = try CourseChanges(json: CourseChangesTests.feed([
                CourseChangesTests.row(1, "assessment", course: "CS3001301", days: ["2026-11-05"], values: Self.exam),
                CourseChangesTests.row(2, "online", course: "CS3002301", days: ["2026-11-05"]),
            ]))
            let slots = CourseTimeSlot.buildSlots(from: courses, weekday: 4, on: thursday, changes: changes)
            let cards = VStack(spacing: 12) {
                ForEach(slots) { CourseTimeCard(state: .inClass([.course($0)]), onSelect: { _ in }) }
            }
            .padding(16)
            let window = try ClubScreensTests.show(cards, look: look.club, width: look.width, height: 260)
            defer { window.isHidden = true }
            let assessment = String(localized: "course_change_assessment")
            try await waitUntil { exposedAccessibilityLabels(in: window).contains { $0.contains("作業系統, \(assessment)") } }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "course-card-\(look.testDescription)")

            let labels = exposedAccessibilityLabels(in: window)
            #expect(labels.contains { $0.contains(String(localized: "course_change_online")) && $0.contains("計算機網路") })
            #expect(!labels.contains { $0.contains("計算機網路, \(assessment)") })
        }
    }

    @Test("the class table's today cards underline an assessment but not a cancelled one, and show an online class in its room's place", arguments: looks)
    func todayCards(look: Look) async throws {
        try await withAccessibilityAutomation {
            let now = AppClock.now()
            let today = [TaipeiTime.dayKey(for: now)]
            func course(_ courseNo: String, _ name: String, _ room: String, _ periods: [String]) -> SDCourse {
                SDCourse(courseNo: courseNo, courseName: name, classroom: room, schedule: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, periods) }))
            }
            let courses = [
                course("CS3001301", "作業系統", "TR-313", ["2", "3"]),
                course("CS3002301", "計算機網路", "IB-201", ["4"]),
                course("CS3003301", "資料結構", "TR-412", ["6", "7"]),
                course("EE3004301", "電子學", "EE-404", ["8", "9"]),
            ]
            let changes = try CourseChanges(json: CourseChangesTests.feed([
                CourseChangesTests.row(1, "assessment", course: "CS3001301", days: today, values: Self.exam),
                CourseChangesTests.row(2, "online", course: "CS3002301", days: today),
                CourseChangesTests.row(3, "assessment", course: "CS3003301", days: today, values: Self.exam),
                CourseChangesTests.row(4, "online", course: "CS3003301", days: today),
                CourseChangesTests.row(5, "assessment", course: "EE3004301", days: today, values: Self.exam),
                CourseChangesTests.row(6, "cancelled", course: "EE3004301", days: today),
            ]))
            let ongoing = courses.prefix(2).map { course in
                OngoingCourseInfo(slot: CourseTimeSlot.buildSlots(from: [course], weekday: now.scheduleWeekday, on: now, changes: changes)[0], course: course)
            }
            let carousel = TodayCourseCarousel(
                courses: courses, hasAssignment: { _ in false }, showProgress: false, ongoing: ongoing, changes: changes
            )
            let window = try ClubScreensTests.show(carousel, look: look.club, width: look.width, height: 260)
            defer { window.isHidden = true }
            let assessment = String(localized: "course_change_assessment")
            let online = String(localized: "course_change_online")
            try await waitUntil { exposedAccessibilityLabels(in: window).contains { $0.contains("作業系統, \(assessment)") } }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "today-cards-\(look.testDescription)")

            let labels = exposedAccessibilityLabels(in: window)
            let network = try #require(labels.first { $0.contains("計算機網路") })
            #expect(network.contains(online) && !network.contains(assessment))
            let structures = try #require(labels.first { $0.contains("資料結構") })
            #expect(structures.contains("資料結構, \(assessment)") && structures.contains(online) && !structures.contains("TR-412"))
            #expect(labels.first { $0.contains("電子學") }?.contains(assessment) == false)
        }
    }

    @Test("an assessment draws a thick, dense dashed line in its ink under every line of the course name", arguments: [looks[0], looks[1]])
    func assessmentUnderline(look: Look) async throws {
        let (ink, text): (UInt32, UInt32) = look.style == .dark ? (AssessmentInk.dark, 0xFFFFFF) : (AssessmentInk.light, 0x000000)
        let name = CourseName(Self.longName, isAssessment: true)
            .font(TigerDuckTheme.Typography.headline)
            .foregroundStyle(Color.textPrimary)
            .frame(width: 150)
            .padding(16)
        let window = try ClubScreensTests.show(name, look: look.club, width: 182, height: 180)
        defer { window.isHidden = true }
        try await waitUntil { InkScan(window.picture(), ink: ink, text: text).map { $0.bands.count >= 2 } ?? false }
        window.saveSnapshot(as: "assessment-underline-\(look.testDescription)")
        let scan = try #require(InkScan(window.picture(), ink: ink, text: text))

        #expect(scan.bands.count == scan.textLines)
        for band in scan.bands {
            #expect(band.height >= 1.6)
            #expect(band.dashes >= max(2, Int(band.width / 7)))
        }
        #expect(scan.mostCommonInk.map { InkScan.near($0, ink, by: 3) } == true)
    }
}

private struct InkScan {
    struct Band {
        let height: CGFloat
        let width: CGFloat
        let dashes: Int
    }

    let bands: [Band]
    let textLines: Int
    let mostCommonInk: UInt32?

    init?(_ picture: UIImage, ink: UInt32, text: UInt32) {
        guard let image = picture.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let (width, height, scale) = (image.width, image.height, picture.scale)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context != nil
        }
        guard drawn else { return nil }
        func color(_ x: Int, _ y: Int) -> UInt32 {
            let index = (y * width + x) * 4
            return UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
        }
        func redness(_ color: UInt32) -> Int { Int(color >> 16) - Int((color >> 8) & 0xFF) }
        let inkColumns = (0..<height).map { y in
            (0..<width).filter { Self.near(color($0, y), ink, by: 40) && abs(redness(color($0, y)) - redness(ink)) <= 20 }
        }
        let textRows = (0..<height).filter { y in
            (0..<width).contains { Self.near(color($0, y), text, by: 60) }
        }
        let inkRows = (0..<height).filter { inkColumns[$0].count >= 3 }
        var counts: [UInt32: Int] = [:]
        bands = Self.runs(of: inkRows, joining: 1).map { rows in
            let columns = inkColumns[rows[rows.count / 2]]
            for x in columns { counts[color(x, rows[rows.count / 2]), default: 0] += 1 }
            return Band(
                height: CGFloat(rows.count) / scale, width: CGFloat(columns.last! - columns.first! + 1) / scale,
                dashes: Self.runs(of: columns, joining: 1).count
            )
        }
        textLines = Self.runs(of: textRows.filter { !inkRows.contains($0) }, joining: Int(3 * scale)).count
        mostCommonInk = counts.max { $0.value < $1.value }?.key
    }

    static func near(_ color: UInt32, _ other: UInt32, by tolerance: Int) -> Bool {
        [16, 8, 0].allSatisfy { abs(Int((color >> $0) & 0xFF) - Int((other >> $0) & 0xFF)) <= tolerance }
    }

    private static func runs(of values: [Int], joining gap: Int) -> [[Int]] {
        values.reduce(into: [[Int]]()) { runs, value in
            if let last = runs.last?.last, value - last <= gap + 1 { runs[runs.count - 1].append(value) } else { runs.append([value]) }
        }
    }
}
#endif

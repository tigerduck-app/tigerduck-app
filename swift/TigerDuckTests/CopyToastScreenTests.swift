#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct CopyToastScreenTests {
    typealias Look = ClubScreensTests.Look

    static let policy = VisualStylePolicy(preset: .default)
    static let courseLocation = String(localized: "course_detail_location_label")
    static let clubLocation = String(localized: "class_table_club_location_label")
    static let copyLocation = String(localized: "class_table_copy_location")
    static let locationCopied = String(localized: "class_table_location_copied")
    static let codeLabel = String(localized: "course_detail_code_label")
    static let copyCode = String(localized: "course_detail_copy_code")
    static let codeCopied = String(localized: "course_detail_code_copied")
    static let instructorLabel = String(localized: "course_detail_instructor_label")
    static let copyInstructor = String(localized: "course_detail_copy_instructor")
    static let instructorCopied = String(localized: "course_detail_instructor_copied")
    static let longLocations = [
        "國際大樓 IB-1201 會議室（需換證）",
        "International Building IB-1201 Conference Room (exchange your ID at the desk)",
    ]

    static let longInstructors = [
        "王大明、陳美玲、林志豪、張雅婷、李建宏、黃淑芬",
        "Alexander Montgomery-Richardson, Maria Fernanda Gutierrez-Lopez",
    ]
    static let longCourseNames = [
        "資料結構與演算法設計實務專題研討（全英語授課）",
        "Special Topics in the Practice of Data Structures and Algorithm Design (taught in English)",
    ]

    static func course(
        classroom: String = "TR-313", instructor: String = "王大明", name: String = "資料結構與演算法"
    ) -> CourseStore.Course {
        CourseStore.Course(
            courseNo: "CS2001301", courseName: name, instructor: instructor, credits: 3,
            classroom: classroom, enrolledCount: 40, maxCount: 60, schedule: [1: ["2", "3"]], semester: ""
        )
    }

    static func meeting(of course: CourseStore.Course, movedTo room: String) -> CourseTimeSlot {
        let start = ClubScreensTests.monday.addingTimeInterval(9 * 3600)
        var meeting = CourseTimeSlot(id: "moved", course: course, start: start, end: start.addingTimeInterval(7200), date: start)
        meeting.changes = [CourseChange(
            id: 1, courseNo: course.courseNo, kind: .room, periods: .everyPeriodThatDay,
            room: room, startHHmm: nil, endHHmm: nil, noteZh: nil, noteEn: nil
        )]
        return meeting
    }

    static func club(at location: String) throws -> ClubOccurrence {
        let club = try #require(ClubMock.occurrences(on: 1).first)
        return ClubOccurrence(
            id: club.id, clubID: club.clubID, clubName: club.clubName, color: club.color, priority: club.priority,
            day: club.day, start: club.start, end: club.end, location: location, kind: club.kind, name: club.name,
            content: club.content
        )
    }

    /// `CourseDetailSheet` reads the app's `AppEnvironment`, which the test host never builds, so
    /// this lays out its cards and rows the same way under the same toast host.
    struct CourseSheet: View {
        let course: CourseStore.Course
        var meeting: CourseTimeSlot?
        var detents: Set<PresentationDetent> = [.medium, .large]

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    DetailSheetHeader(title: course.displayName, subtitle: nil, color: course.color)
                    CourseDetailRoomAndTime(
                        course: course, times: nil, weekday: 1, periods: nil, meeting: meeting,
                        policy: CopyToastScreenTests.policy
                    )
                    CourseDetailInfoRows(course: course)
                }
                .padding(.top, TigerDuckTheme.Spacing.xl)
                .padding(.bottom, TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
            .toastHost()
            .presentationDetents(detents)
        }
    }

    static func element(_ label: String, in window: UIWindow) async throws -> NSObject {
        try await waitUntil { accessibilityElement(labeled: label, in: window) != nil }
        return try #require(accessibilityElement(labeled: label, in: window))
    }

    /// Taps again, the window brought to the front, while `text` does not show: another suite's
    /// window can cover it while suites run side by side, and on iOS 26.5 a new window's first touch
    /// can go nowhere.
    static func tap(_ element: NSObject, in window: UIWindow, until text: String) async throws {
        let point = window.convert(element.accessibilityActivationPoint, from: window.screen.coordinateSpace)
        for _ in 0..<5 {
            window.makeKeyAndVisible()
            try await fingerTap(at: point, in: window)
            if try await PageMenuScreenTests.holds(within: .seconds(5), { accessibilityElement(labeled: text, in: window) != nil }) { return }
        }
    }

    static func pixels(of element: NSObject, in window: UIWindow) -> Data? {
        picture(of: element, in: window).pngData()
    }

    static func picture(of element: NSObject, in window: UIWindow, widenedBy margin: CGFloat = 0) -> UIImage {
        let frame = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
        return UIGraphicsImageRenderer(bounds: frame.insetBy(dx: -margin, dy: 0)).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The groups of drawn columns across a row, split where at least `gap` points of background lie
    /// between them: a row's label and its value are two.
    static func inkGroups(of element: NSObject, in window: UIWindow, gap: CGFloat = 4) throws -> Int {
        let picture = Self.picture(of: element, in: window, widenedBy: 2)
        let image = try #require(picture.cgImage)
        let (width, height) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context != nil
        }
        try #require(drawn)
        let background = bytes[0..<3].map(Int.init)
        let inked = (0..<width).map { x in
            (0..<height).contains { y in
                let pixel = (y * width + x) * 4
                return (0..<3).map { abs(Int(bytes[pixel + $0]) - background[$0]) }.reduce(0, +) > 60
            }
        }
        let minimumGap = Int((gap * picture.scale).rounded())
        var groups = 0, blank = minimumGap
        for column in inked {
            if column {
                if blank >= minimumGap { groups += 1 }
                blank = 0
            } else {
                blank += 1
            }
        }
        return groups
    }

    @Test("a tap on the course sheet's location card copies the room it shows and says so", arguments: [false, true])
    func copiesTheCourseLocation(moved: Bool) async throws {
        try await withAccessibilityAutomation {
            let course = Self.course()
            let shown = moved ? "IB-1201" : "TR-313"
            let sheet = CourseSheet(course: course, meeting: moved ? Self.meeting(of: course, movedTo: shown) : nil)
            let window = try ClubScreensTests.show(sheet, look: ClubScreensTests.looks[0], height: 874)
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            let card = try await Self.element("\(Self.courseLocation), \(shown)", in: window)
            #expect(card.accessibilityTraits.contains(.button))
            #expect(card.accessibilityHint == Self.copyLocation)
            try await Self.tap(card, in: window, until: Self.locationCopied)

            try await waitUntil { accessibilityElement(labeled: Self.locationCopied, in: window) != nil }
            #expect(UIPasteboard.general.string == shown)
        }
    }

    @Test("a tap or VoiceOver's activation of the club sheet's location card copies it and says so", arguments: [false, true])
    func copiesTheClubLocation(byVoiceOver: Bool) async throws {
        try await withAccessibilityAutomation {
            let club = try Self.club(at: "學生活動中心 B1")
            let window = try ClubScreensTests.show(
                ClubActivityDetailSheet(club: club, policy: Self.policy), look: ClubScreensTests.looks[0], height: 874
            )
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            let card = try await Self.element("\(Self.clubLocation), \(club.location)", in: window)
            #expect(card.accessibilityTraits.contains(.button))
            #expect(card.accessibilityHint == Self.copyLocation)
            if byVoiceOver {
                #expect(card.accessibilityActivate())
            } else {
                try await Self.tap(card, in: window, until: Self.locationCopied)
            }

            try await waitUntil { accessibilityElement(labeled: Self.locationCopied, in: window) != nil }
            #expect(UIPasteboard.general.string == club.location)
        }
    }

    @Test("a tap on the course code copies it and says so in a toast, with no checkmark in the row", arguments: [false, true])
    func copiesTheCourseCode(byVoiceOver: Bool) async throws {
        try await withAccessibilityAutomation {
            let course = Self.course()
            let window = try ClubScreensTests.show(CourseSheet(course: course), look: ClubScreensTests.looks[0], height: 874)
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            let row = try await Self.element("\(Self.codeLabel), \(course.courseNo)", in: window)
            #expect(row.accessibilityTraits.contains(.button))
            #expect(row.accessibilityHint == Self.copyCode)
            try await Task.sleep(for: .milliseconds(400))
            let before = Self.pixels(of: row, in: window)
            if byVoiceOver {
                #expect(row.accessibilityActivate())
            } else {
                try await Self.tap(row, in: window, until: Self.codeCopied)
            }

            try await waitUntil { accessibilityElement(labeled: Self.codeCopied, in: window) != nil }
            #expect(UIPasteboard.general.string == course.courseNo)
            // A finger's press dims the row for a moment; VoiceOver's activation leaves it as drawn.
            if byVoiceOver {
                try await Task.sleep(for: .milliseconds(400))
                #expect(Self.pixels(of: row, in: window) == before)
            }
        }
    }

    /// Default text sizes only: at the largest one the row lies below the window.
    @Test(
        "the course code row draws its label and its value and nothing between them",
        arguments: ClubScreensTests.looks.filter { !$0.textSize.isAccessibilityCategory }
    )
    func codeRowHasNoGlyph(look: Look) async throws {
        try await withAccessibilityAutomation {
            let course = Self.course()
            let window = try ClubScreensTests.show(CourseSheet(course: course), look: look, height: 874)
            defer { window.isHidden = true }

            let row = try await Self.element("\(Self.codeLabel), \(course.courseNo)", in: window)
            try await Task.sleep(for: .milliseconds(400))
            #expect(try Self.inkGroups(of: row, in: window) == 2)
        }
    }

    @Test("a tap or VoiceOver's activation of the instructor row copies the instructor and says so", arguments: [false, true])
    func copiesTheInstructor(byVoiceOver: Bool) async throws {
        try await withAccessibilityAutomation {
            let course = Self.course(instructor: " 王大明 ")
            let window = try ClubScreensTests.show(CourseSheet(course: course), look: ClubScreensTests.looks[0], height: 874)
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            let row = try await Self.element("\(Self.instructorLabel), 王大明", in: window)
            #expect(row.accessibilityTraits.contains(.button))
            #expect(row.accessibilityHint == Self.copyInstructor)
            if byVoiceOver {
                #expect(row.accessibilityActivate())
            } else {
                try await Self.tap(row, in: window, until: Self.instructorCopied)
            }

            try await waitUntil { accessibilityElement(labeled: Self.instructorCopied, in: window) != nil }
            #expect(UIPasteboard.general.string == "王大明")
        }
    }

    @Test("an empty or blank instructor shows a dash that is no button and copies nothing", arguments: ["", " \n "])
    func blankInstructor(instructor: String) async throws {
        try await withAccessibilityAutomation {
            let window = try ClubScreensTests.show(
                CourseSheet(course: Self.course(instructor: instructor)), look: ClubScreensTests.looks[0], height: 874
            )
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            let dash = try await Self.element("—", in: window)
            #expect(!exposedAccessibilityElements(in: window).contains { $0.accessibilityHint == Self.copyInstructor })
            #expect(!dash.accessibilityTraits.contains(.button))
            #expect(!dash.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(600))

            #expect(accessibilityElement(labeled: Self.instructorCopied, in: window) == nil)
            #expect(UIPasteboard.general.string == "before")
        }
    }

    @Test("an empty or blank location shows a dash that is no button and copies nothing", arguments: [false, true], ["", " \n "])
    func emptyLocation(onClubSheet: Bool, location: String) async throws {
        try await withAccessibilityAutomation {
            let club = try Self.club(at: location)
            let sheet = onClubSheet
                ? AnyView(ClubActivityDetailSheet(club: club, policy: Self.policy))
                : AnyView(CourseSheet(course: Self.course(classroom: location)))
            let window = try ClubScreensTests.show(sheet, look: ClubScreensTests.looks[0], height: 874)
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            let dash = try await Self.element("—", in: window)
            #expect(!exposedAccessibilityElements(in: window).contains { $0.accessibilityHint == Self.copyLocation })
            #expect(!dash.accessibilityTraits.contains(.button))
            #expect(!dash.accessibilityActivate())
            try await Task.sleep(for: .milliseconds(600))

            #expect(accessibilityElement(labeled: Self.locationCopied, in: window) == nil)
            #expect(UIPasteboard.general.string == "before")
        }
    }

    struct Shot: CustomTestStringConvertible {
        enum Kind: String {
            case courseLocation = "course-location", courseCode = "course-code", courseInstructor = "course-instructor", club
        }

        let kind: Kind
        let width: CGFloat
        let look: Look
        let location: String

        var testDescription: String {
            let language = location == CopyToastScreenTests.longLocations[0] ? "zh" : "en"
            return "\(kind.rawValue)-\(Int(width))-\(look.testDescription)-\(language)-location"
        }
    }

    static let shots: [Shot] = [Shot.Kind.courseLocation, .courseCode, .courseInstructor, .club].flatMap { kind in
        SettingsSnapshotTests.widths.flatMap { width in
            ClubScreensTests.looks.flatMap { look in
                (kind == .courseCode ? [longLocations[0]] : longLocations).map {
                    Shot(kind: kind, width: width, look: look, location: $0)
                }
            }
        }
    }

    @Test("each sheet with its toast up keeps the toast and the cards on the phone", arguments: shots)
    func snapshot(shot: Shot) async throws {
        try await withAccessibilityAutomation {
            let long = Self.longLocations.firstIndex(of: shot.location) ?? 0
            let course = shot.kind == .courseInstructor
                ? Self.course(classroom: shot.location, instructor: Self.longInstructors[long], name: Self.longCourseNames[long])
                : Self.course(classroom: shot.location)
            let club = try Self.club(at: shot.location)
            let sheet = shot.kind == .club
                ? AnyView(ClubActivityDetailSheet(club: club, policy: Self.policy))
                : AnyView(CourseSheet(course: course, detents: shot.kind == .courseInstructor ? [.large] : [.medium, .large]))
            let window = try ClubScreensTests.show(
                Color.clear.sheet(isPresented: .constant(true)) { sheet }, look: shot.look, width: shot.width, height: 874
            )
            defer {
                window.rootViewController?.dismiss(animated: false)
                window.isHidden = true
            }
            let (target, toast) = switch shot.kind {
            case .courseLocation: ("\(Self.courseLocation), \(shot.location)", Self.locationCopied)
            case .courseCode: ("\(Self.codeLabel), \(course.courseNo)", Self.codeCopied)
            case .courseInstructor: ("\(Self.instructorLabel), \(course.instructor)", Self.instructorCopied)
            case .club: ("\(Self.clubLocation), \(shot.location)", Self.locationCopied)
            }
            let card = try await Self.element(target, in: window)
            try await Task.sleep(for: .milliseconds(600))
            #expect(card.accessibilityActivate())
            let shown = try await Self.element(toast, in: window)
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "copy-toast-\(shot.testDescription)-\(Self.language)-ios\(UIDevice.current.systemVersion)")

            let screen = window.convert(window.bounds, to: window.screen.coordinateSpace)
            #expect(screen.contains(shown.accessibilityFrame), "toast at \(shown.accessibilityFrame)")
            let cardFrame = card.accessibilityFrame
            #expect(cardFrame.minX >= screen.minX && cardFrame.maxX <= screen.maxX, "card at \(cardFrame)")
        }
    }

    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
}
#endif

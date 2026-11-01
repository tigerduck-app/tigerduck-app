import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct LateMoodleIdColorTests {
    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LateMoodleIdColorTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = TestCache(folders: CacheFolders(root: root))
        lazy var colors = CourseColorStore(files: cache.colors)
        var syncsAsked = 0

        init(courses: [String]) {
            cache.courses.saveCourses(courses.map { courseNo in
                SDCourse(courseNo: courseNo, courseName: courseNo, moodleIdNumber: "\(Self.term)\(courseNo)", semester: Self.term)
            }, semester: Self.term, for: testSignIn)
            colors.onLateMoodleColors = { [unowned self] in self.syncsAsked += 1 }
        }

        static let term = CourseSelectionService.currentSemesterCode()

        func storeIds(_ ids: [String: Int], for signIn: SignIn = testSignIn) {
            CourseLookup.replaceMoodleCourseIds(
                ids.reduce(into: [:]) { $0["\(Self.term)\($1.key)"] = $1.value },
                for: signIn, moodle: cache.moodle, courses: cache.courses, colors: colors
            )
        }

        func giveColours() {
            colors.ensureAssignments(
                courses: cache.courses.loadCourses(semester: Self.term), ids: cache.moodle.loadMoodleCourseIdMap(),
                palette: TigerDuckTheme.coursePaletteHexes, for: testSignIn
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let moodle = TigerDuckTheme.moodleCourseColors
    private static let palette = TigerDuckTheme.coursePaletteHexes

    @Test("A Moodle id that arrives after the course's colour moves it to Moodle's colour and asks for a sync")
    func aLateMoodleIdMovesAnAutomaticColour() throws {
        let folder = Folder(courses: ["CS1", "CS2"])
        folder.storeIds(["CS2": 5332])
        folder.giveColours()
        let before = try #require(folder.colors.map["CS1"])
        #expect(Self.palette.contains(before))

        folder.storeIds(["CS1": 4127, "CS2": 5332])

        #expect(folder.colors.map == ["CS1": Self.moodle[7], "CS2": Self.moodle[2]])
        #expect(folder.colors.lateMoodleColors == ["CS1": Self.moodle[7]])
        #expect(folder.syncsAsked == 1)
    }

    @Test("A colour the user picked stays when the course's Moodle id arrives")
    func aPickedColourSurvivesALateMoodleId() {
        let folder = Folder(courses: ["CS1"])
        folder.storeIds([:])
        folder.giveColours()
        folder.colors.pick(0x123456, courseNo: "CS1", palette: Self.palette, for: testSignIn)

        folder.storeIds(["CS1": 4127])

        #expect(folder.colors.map == ["CS1": 0x123456])
        #expect(folder.colors.lateMoodleColors.isEmpty)
        #expect(folder.syncsAsked == 0)
    }

    @Test("The first id map a sign-in stores moves no colour, as the colours it finds may be another device's")
    func theFirstIdMapMovesNoColour() throws {
        let folder = Folder(courses: ["CS1"])
        folder.giveColours()
        let before = try #require(folder.colors.map["CS1"])

        folder.storeIds(["CS1": 4127])

        #expect(folder.colors.map == ["CS1": before])
        #expect(folder.colors.lateMoodleColors.isEmpty)
    }

    @Test("A Moodle id that arrives for a sign-in that has ended moves no colour")
    func aLateIdAfterTheSignInEndedIsDropped() throws {
        let folder = Folder(courses: ["CS1"])
        folder.storeIds([:])
        folder.giveColours()
        let before = try #require(folder.colors.map["CS1"])

        folder.storeIds(["CS1": 4127], for: endedTestSignIn)
        folder.colors.takeMoodleColors(["CS1": Self.moodle[7]], for: endedTestSignIn)

        #expect(folder.colors.map == ["CS1": before])
        #expect(folder.colors.lateMoodleColors.isEmpty)
    }

    private static let resetClock = PushAPI.clock(of: Date(timeIntervalSince1970: 1_790_000_000))
    private static let snapshot: [String: Any] = ["term_resets": ["1151": resetClock]]
    private static let courseRows: [[String: Any]] = [
        ["course_key": "client:1151:CS1", "semester": "1151", "course_no": "CS1", "moodle_id": "1151CS1"],
    ]

    private static func serverColour(_ hex: UInt32, at clock: Int64) -> [[String: Any]] {
        [["moodle_id": "1151CS1", "semester": "1151", "course_no": "CS1",
          "color_hex": String(format: "#%06X", hex), "color_hex_hlc": clock]]
    }

    @Test("A colour a late Moodle id gave goes out as an automatic one: over the backend's automatic colour, under any pick")
    func aLateMoodleColourIsSentAsAnAutomaticColour() throws {
        let local = ["CS1": Self.moodle[7]]
        let automatic = try #require(CourseOverridesReconciler.colorFills(
            [], courses: Self.courseRows, local: ["CS1": 0xFF6B6B], holding: [], snapshot: Self.snapshot
        ).first)
        let server = Self.serverColour(0xFF6B6B, at: PushAPI.clock(of: automatic.stamp))

        let held = CourseOverridesReconciler.lateMoodleColors(
            server, courses: Self.courseRows, moved: local, local: local, snapshot: Self.snapshot
        )
        #expect(held == ["1151CS1"])
        #expect(CourseOverridesReconciler.serverCourseColors(server, courseNos: [:], holding: held).isEmpty)
        let fill = try #require(CourseOverridesReconciler.colorFills(
            server, courses: Self.courseRows, local: local, holding: [], snapshot: Self.snapshot
        ).first)
        #expect(fill.colorHex == String(format: "#%06X", Self.moodle[7]))
        #expect(PushAPI.clock(of: fill.stamp) > PushAPI.clock(of: automatic.stamp))
        #expect(PushAPI.clock(of: fill.stamp) < Self.resetClock + 1_000_000)

        let picked = Self.serverColour(0x123456, at: Self.resetClock + 60_000_000)
        #expect(CourseOverridesReconciler.lateMoodleColors(
            picked, courses: Self.courseRows, moved: local, local: local, snapshot: Self.snapshot
        ).isEmpty)
        #expect(CourseOverridesReconciler.lateMoodleColors(
            server, courses: Self.courseRows, moved: local, local: ["CS1": 0x123456], snapshot: Self.snapshot
        ).isEmpty)
    }
}

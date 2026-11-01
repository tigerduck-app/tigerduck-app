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
        lazy var colors = relaunch()
        var syncsAsked = 0

        func relaunch() -> CourseColorStore {
            let store = CourseColorStore(files: cache.colors)
            store.onLateMoodleColors = { [unowned self] in self.syncsAsked += 1 }
            return store
        }

        func storeIds(_ ids: [String: Int]) {
            cache.moodle.replaceMoodleCourseIdMap(ids.reduce(into: [:]) { $0["1151\($1.key)"] = $1.value }, for: testSignIn)
        }

        func giveColours(_ courseNos: [String], for signIn: SignIn = testSignIn) {
            colors.ensureAssignments(
                courses: courseNos.map(LateMoodleIdColorTests.course), ids: { self.cache.moodle.loadMoodleCourseIdMap() },
                palette: TigerDuckTheme.coursePaletteHexes, for: signIn
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let moodle = TigerDuckTheme.moodleCourseColors
    private static let palette = TigerDuckTheme.coursePaletteHexes
    private static let red: UInt32 = 0xFF6B6B
    private static let teal: UInt32 = 0x4ECDC4

    private static func course(_ courseNo: String) -> SDCourse {
        SDCourse(courseNo: courseNo, courseName: courseNo, moodleIdNumber: "1151\(courseNo)", semester: "1151")
    }

    @Test("A Moodle id that arrives after the course's colour moves it to Moodle's colour and asks for a sync")
    func aLateMoodleIdMovesAnAutomaticColour() throws {
        let folder = Folder()
        folder.storeIds(["CS2": 5332])
        folder.giveColours(["CS1", "CS2"])
        #expect(Self.palette.contains(try #require(folder.colors.map["CS1"])))

        folder.storeIds(["CS1": 4127, "CS2": 5332])
        folder.giveColours(["CS1", "CS2"])

        #expect(folder.colors.map == ["CS1": Self.moodle[7], "CS2": Self.moodle[2]])
        #expect(folder.colors.lateMoodleColors == ["CS1": Self.moodle[7]])
        #expect(folder.syncsAsked == 1)
    }

    @Test("A course first loaded with no Moodle id number moves once a later load gives it one the map holds")
    func aCourseLoadedWithoutAnIdNumberMovesLater() throws {
        let folder = Folder()
        folder.storeIds(["CS1": 4127])
        let fromTranscript = SDCourse(courseNo: "CS1", courseName: "CS1", semester: "1151")
        folder.colors.ensureAssignments(
            courses: [fromTranscript], ids: { folder.cache.moodle.loadMoodleCourseIdMap() },
            palette: Self.palette, for: testSignIn
        )
        #expect(Self.palette.contains(try #require(folder.colors.map["CS1"])))

        folder.giveColours(["CS1"])

        #expect(folder.colors.map == ["CS1": Self.moodle[7]])
        #expect(folder.colors.lateMoodleColors == ["CS1": Self.moodle[7]])
    }

    @Test("A colour the user picked stays when the course's Moodle id arrives")
    func aPickedColourSurvivesALateMoodleId() {
        let folder = Folder()
        folder.giveColours(["CS1"])
        folder.colors.pick(0x123456, courseNo: "CS1", palette: Self.palette, for: testSignIn)

        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1"])

        #expect(folder.colors.map == ["CS1": 0x123456])
        #expect(folder.colors.lateMoodleColors.isEmpty)
    }

    @Test("A reset leaves no course waiting, so with sync off a Moodle id found later keeps the reset's colour")
    func aResetLeavesNoWaitsWithSyncOff() throws {
        let folder = Folder()
        folder.giveColours(["CS1"])

        folder.colors.reassignAll(courses: [Self.course("CS1")], ids: [:], palette: Self.palette, for: testSignIn)
        let reset = try #require(folder.colors.map["CS1"])
        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1"])

        #expect(folder.cache.colors.loadMoodleColorWaits() == MoodleColorWaits())
        #expect(folder.colors.map == ["CS1": reset])
        #expect(folder.syncsAsked == 0)
    }

    @Test("A reset ends every wait and unsent mark, so with sync on its own echo is neither held nor moved")
    func aResetLeavesNoWaitsWithSyncOn() throws {
        let folder = Folder()
        folder.giveColours(["CS1", "CS2"])
        folder.storeIds(["CS2": 5332])
        folder.giveColours(["CS1", "CS2"])
        #expect(folder.colors.lateMoodleColors == ["CS2": Self.moodle[2]])

        folder.colors.reassignAll(courses: [Self.course("CS1"), Self.course("CS2")], ids: [:], palette: Self.palette, for: testSignIn)
        let reset = try #require(folder.colors.map["CS1"])
        let echo = Self.serverColour(reset, at: Self.resetClock + 60_000_000)
        #expect(Self.late(echo, folder.colors.lateMoodleColors).holding.isEmpty)
        folder.storeIds(["CS1": 4127, "CS2": 5332])
        folder.giveColours(["CS1", "CS2"])

        #expect(folder.cache.colors.loadMoodleColorWaits() == MoodleColorWaits())
        #expect(folder.colors.map["CS1"] == reset)
        #expect(folder.colors.lateMoodleColors.isEmpty)
    }

    @Test("Picking the colour a course already has ends its wait, so its Moodle id moves it no more")
    func pickingTheSameColourEndsTheWait() throws {
        let folder = Folder()
        folder.giveColours(["CS1"])
        let automatic = try #require(folder.colors.map["CS1"])
        folder.colors.pick(automatic, courseNo: "CS1", palette: Self.palette, for: testSignIn)

        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1"])

        #expect(folder.colors.map == ["CS1": automatic])
        #expect(folder.colors.lateMoodleColors.isEmpty)
    }

    @Test("A colour another device chose ends the wait when pulled, though it is the colour here already")
    func pullingTheSameChosenColourEndsTheWait() throws {
        let folder = Folder()
        folder.giveColours(["CS1"])
        let automatic = try #require(folder.colors.map["CS1"])
        let chosen = Self.serverColour(automatic, at: Self.resetClock + 60_000_000)
        let echo = Self.serverColour(automatic, at: Self.automaticFillClock)
        #expect(CourseOverridesReconciler.colorChoices(echo, courses: Self.courseRows, holding: [], snapshot: Self.snapshot).isEmpty)
        #expect(CourseOverridesReconciler.colorChoices(chosen, courses: Self.courseRows, holding: ["1151CS1"], snapshot: Self.snapshot).isEmpty)

        let choices = CourseOverridesReconciler.colorChoices(chosen, courses: Self.courseRows, holding: [], snapshot: Self.snapshot)
        folder.colors.applyColors([("CS1", automatic)], palette: Self.palette, for: testSignIn)
        folder.colors.endMoodleWaits(choices, for: testSignIn)
        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1"])

        #expect(choices == ["CS1"])
        #expect(folder.colors.map == ["CS1": automatic])
    }

    @Test("A colour pulled from another device stays when the course's Moodle id arrives")
    func aPulledColourIsNotOverwrittenByALateId() {
        let folder = Folder()
        folder.giveColours(["CS1"])
        folder.colors.applyColors([("CS1", 0x123456)], palette: Self.palette, for: testSignIn)

        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1"])

        #expect(folder.colors.map == ["CS1": 0x123456])
        #expect(folder.colors.lateMoodleColors.isEmpty)
    }

    @Test("Courses coloured before an upgrade keep their colours though their Moodle ids are stored")
    func anUpgradeWithAStoredMapMovesNothing() {
        let folder = Folder()
        folder.cache.colors.saveCourseColorMap(["CS1": Self.red, "CS2": Self.teal])
        folder.storeIds(["CS1": 4127, "CS2": 5332])

        folder.giveColours(["CS1", "CS2"])

        #expect(folder.colors.map == ["CS1": Self.red, "CS2": Self.teal])
        #expect(folder.syncsAsked == 0)
    }

    @Test("An empty Moodle list and then a full one move only the courses awaiting their Moodle colour")
    func anEmptyMapThenAFullOneMovesOnlyAwaitingCourses() {
        let folder = Folder()
        folder.cache.colors.saveCourseColorMap(["CS1": Self.red])
        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1", "CS2"])

        folder.storeIds([:])
        folder.giveColours(["CS1", "CS2"])
        folder.storeIds(["CS1": 4127, "CS2": 5332])
        folder.giveColours(["CS1", "CS2"])

        #expect(folder.colors.map == ["CS1": Self.red, "CS2": Self.moodle[2]])
        #expect(folder.colors.lateMoodleColors == ["CS2": Self.moodle[2]])
    }

    @Test("A Moodle id that arrives for a sign-in that has ended moves no colour, and the course still awaits it")
    func aLateIdAfterTheSignInEndedIsDropped() throws {
        let folder = Folder()
        folder.giveColours(["CS1"])
        let before = try #require(folder.colors.map["CS1"])
        folder.storeIds(["CS1": 4127])

        folder.giveColours(["CS1"], for: endedTestSignIn)
        #expect(folder.colors.map == ["CS1": before])
        #expect(folder.colors.lateMoodleColors.isEmpty)

        folder.giveColours(["CS1"])
        #expect(folder.colors.map == ["CS1": Self.moodle[7]])
    }

    private static let resetClock = PushAPI.clock(of: Date(timeIntervalSince1970: 1_790_000_000))
    private static let snapshot: [String: Any] = ["term_resets": ["1151": resetClock]]
    private static let courseRows: [[String: Any]] = [
        ["course_key": "client:1151:CS1", "semester": "1151", "course_no": "CS1", "moodle_id": "1151CS1"],
    ]
    private static let automaticFillClock = PushAPI.clock(of: CourseOverridesReconciler.deterministicFillStamp(
        serverHasColor: false, stampedAt: nil, snapshot: snapshot, semester: "1151"
    ))

    private static func serverColour(_ hex: UInt32, at clock: Int64) -> [[String: Any]] {
        [["moodle_id": "1151CS1", "semester": "1151", "course_no": "CS1",
          "color_hex": String(format: "#%06X", hex), "color_hex_hlc": clock]]
    }

    private static func late(_ server: [[String: Any]], _ moved: [String: UInt32]) -> (holding: Set<String>, sent: Set<String>) {
        CourseOverridesReconciler.lateMoodleColors(server, courses: courseRows, moved: moved, snapshot: snapshot)
    }

    @Test("A move survives a relaunch before the sync, and the next sync sends it")
    func aMoveSurvivesARelaunch() throws {
        let folder = Folder()
        folder.giveColours(["CS1"])
        let automatic = try #require(folder.colors.map["CS1"])
        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1"])

        let relaunched = folder.relaunch()

        #expect(relaunched.map == ["CS1": Self.moodle[7]])
        #expect(relaunched.lateMoodleColors == ["CS1": Self.moodle[7]])
        let server = Self.serverColour(automatic, at: Self.automaticFillClock)
        #expect(Self.late(server, relaunched.lateMoodleColors).holding == ["1151CS1"])
        let fills = CourseOverridesReconciler.colorFills(
            server, courses: Self.courseRows, local: relaunched.map, holding: [], snapshot: Self.snapshot
        )
        #expect(fills.map(\.colorHex) == [String(format: "#%06X", Self.moodle[7])])
    }

    @Test("The move's mark goes once the backend holds the move or a newer colour, and stays while it holds none")
    func theMarkIsDroppedAfterTheServerConfirms() {
        let folder = Folder()
        folder.giveColours(["CS1"])
        folder.storeIds(["CS1": 4127])
        folder.giveColours(["CS1"])
        let moved = folder.colors.lateMoodleColors

        #expect(Self.late([], moved).sent.isEmpty)
        #expect(Self.late(Self.serverColour(0x123456, at: Self.resetClock + 60_000_000), moved).sent == ["CS1"])
        let landed = Self.late(Self.serverColour(Self.moodle[7], at: Self.automaticFillClock + 1_000), moved)
        #expect(landed.holding.isEmpty)
        #expect(landed.sent == ["CS1"])
        folder.colors.endMoodleWaits(landed.sent, for: testSignIn)

        #expect(folder.colors.lateMoodleColors.isEmpty)
        #expect(folder.relaunch().lateMoodleColors.isEmpty)
        #expect(folder.colors.map == ["CS1": Self.moodle[7]])
    }

    @Test("A colour a late Moodle id gave goes out as an automatic one: over the backend's automatic colour, under any pick")
    func aLateMoodleColourIsSentAsAnAutomaticColour() throws {
        let local = ["CS1": Self.moodle[7]]
        let server = Self.serverColour(Self.red, at: Self.automaticFillClock)

        let held = Self.late(server, local).holding
        #expect(held == ["1151CS1"])
        #expect(CourseOverridesReconciler.serverCourseColors(server, courseNos: [:], holding: held).isEmpty)
        let fill = try #require(CourseOverridesReconciler.colorFills(
            server, courses: Self.courseRows, local: local, holding: [], snapshot: Self.snapshot
        ).first)
        #expect(fill.colorHex == String(format: "#%06X", Self.moodle[7]))
        #expect(PushAPI.clock(of: fill.stamp) > Self.automaticFillClock)
        #expect(PushAPI.clock(of: fill.stamp) < Self.resetClock + 1_000_000)

        #expect(Self.late(Self.serverColour(0x123456, at: Self.resetClock + 60_000_000), local).holding.isEmpty)
    }
}

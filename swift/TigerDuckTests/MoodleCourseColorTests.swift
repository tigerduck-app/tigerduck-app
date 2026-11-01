import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MoodleCourseColorTests {
    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleCourseColorTests-\(UUID().uuidString)", isDirectory: true)
        lazy var files = CourseColorFiles(folders: CacheFolders(root: root))
        lazy var store = CourseColorStore(files: files)

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let palette = TigerDuckTheme.coursePaletteHexes
    private static let moodle = TigerDuckTheme.moodleCourseColors
    private static let ids = ["1151CS1": 4127, "1151CS2": 5337, "1151CS3": 902]

    private static func course(_ courseNo: String, moodle: Bool = true) -> SDCourse {
        SDCourse(courseNo: courseNo, courseName: courseNo, moodleIdNumber: moodle ? "1151\(courseNo)" : nil, semester: "1151")
    }

    @Test("Moodle's ten course colours come out readable on both cards, picked by the id's last digit")
    func theTenColoursAreMoodlesMadeReadable() {
        #expect(Self.moodle == [
            0x569E9E, 0x5E96CF, 0x8F88E0, 0x8F9395, 0x00A685, 0x0984E3, 0x8B9498, 0xAF8C4C, 0xE16C96, 0x6C5CE7,
        ])
        #expect(TigerDuckTheme.moodleCourseColor(forCourseId: 4127) == 0xAF8C4C)
        #expect(TigerDuckTheme.moodleCourseColor(forCourseId: 90) == 0x569E9E)
    }

    @Test("A new course with a Moodle id gets the colour Moodle draws it in")
    func aNewCourseWithAMoodleIdGetsItsMoodleColour() {
        let folder = Folder()

        folder.store.ensureAssignments(courses: [Self.course("CS1")], ids: Self.ids, palette: Self.palette, for: testSignIn)

        #expect(folder.store.map == ["CS1": Self.moodle[7]])
    }

    @Test("A course with no known Moodle id gets the colour it got before")
    func aCourseWithoutAMoodleIdKeepsTodaysColour() {
        let without = Folder()
        let with = Folder()
        let courses = [Self.course("CS4"), Self.course("CS5", moodle: false)]

        without.store.ensureAssignments(courses: courses, ids: [:], palette: Self.palette, for: testSignIn)
        with.store.ensureAssignments(courses: courses + [Self.course("CS1")], ids: Self.ids, palette: Self.palette, for: testSignIn)

        #expect(with.store.map["CS4"] == without.store.map["CS4"])
        #expect(with.store.map["CS5"] == without.store.map["CS5"])
        #expect(courses.allSatisfy { with.store.map[$0.courseNo].map(Self.palette.contains) == true })
    }

    @Test("Reassigning every colour gives Moodle's colours and keeps the colour the user picked")
    func aPickedColourSurvivesAReassign() {
        let folder = Folder()
        let courses = [Self.course("CS1"), Self.course("CS3"), Self.course("CS5", moodle: false)]
        folder.store.ensureAssignments(courses: courses, ids: [:], palette: Self.palette, for: testSignIn)
        folder.store.pick(0x123456, courseNo: "CS1", palette: Self.palette, for: testSignIn)

        folder.store.reassignAll(courses: courses, ids: Self.ids, palette: Self.palette, for: testSignIn)

        #expect(folder.store.map["CS1"] == 0x123456)
        #expect(folder.store.map["CS3"] == Self.moodle[2])
        #expect(folder.store.map["CS5"].map(Self.palette.contains) == true)
        #expect(folder.files.loadPickedCourseColors() == ["CS1"])
    }

    @Test("Two courses whose Moodle ids end alike share Moodle's colour, here and from the server")
    func twoCoursesMayShareTheirMoodleColour() {
        let folder = Folder()
        let courses = [Self.course("CS1"), Self.course("CS2")]

        folder.store.ensureAssignments(courses: courses, ids: Self.ids, palette: Self.palette, for: testSignIn)
        folder.store.ensureAssignments(courses: courses, ids: Self.ids, palette: Self.palette, for: testSignIn)
        folder.store.applyColors([("CS9", Self.moodle[7])], palette: Self.palette, for: testSignIn)
        #expect(folder.store.map == ["CS1": Self.moodle[7], "CS2": Self.moodle[7], "CS9": Self.moodle[7]])
        folder.store.reassignAll(courses: courses, ids: Self.ids, palette: Self.palette, for: testSignIn)

        #expect(folder.store.map == ["CS1": Self.moodle[7], "CS2": Self.moodle[7]])
        let pulled = Folder()
        pulled.store.applyColors([("CS1", Self.moodle[7]), ("CS2", Self.moodle[7])], palette: Self.palette, for: testSignIn)
        #expect(pulled.store.map == ["CS1": Self.moodle[7], "CS2": Self.moodle[7]])
    }

    @Test("Moodle colours for a sign-in that has ended are not kept")
    func aWriteAfterTheSignInEndedIsDropped() {
        let folder = Folder()
        let courses = [Self.course("CS1")]

        folder.store.ensureAssignments(courses: courses, ids: Self.ids, palette: Self.palette, for: endedTestSignIn)
        folder.store.reassignAll(courses: courses, ids: Self.ids, palette: Self.palette, for: endedTestSignIn)

        #expect(folder.store.map.isEmpty)
    }
}

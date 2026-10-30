import Testing
@testable import TigerDuck

struct SignOutUnsyncedDataTests {
    private typealias Held = AppState.SignOutData

    private static let categories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]

    private static let kinds: [(data: Held, needs: Set<String>)] = [
        (Held(courses: true), ["courses"]),
        (Held(courseNames: true), ["course_names"]),
        (Held(courseColors: true), ["course_colors"]),
        (Held(assignmentMarks: true), ["assignments"]),
        (Held(ignoredCourses: true), ["assignments", "courses"]),
    ]

    private static let everything = Held(
        courses: true, courseNames: true, courseColors: true,
        assignmentMarks: true, ignoredCourses: true, holidays: true
    )

    private static func deletes(
        _ data: Held,
        cloudSyncEnabled: Bool = true,
        switchedOn: Set<String> = categories,
        synced: Set<String> = categories,
        pendingChecks: Set<String> = [],
        unsent: Bool = false
    ) -> Bool {
        AppState.signOutDeletesUnsyncedData(
            data, cloudSyncEnabled: cloudSyncEnabled, switchedOn: switchedOn, synced: synced,
            pendingChecks: pendingChecks, unsent: unsent
        )
    }

    private static func leaves(
        _ data: Held,
        cloudSyncEnabled: Bool = true,
        switchedOn: Set<String> = categories,
        synced: Set<String> = categories,
        pendingChecks: Set<String> = []
    ) -> Bool {
        AppState.signOutLeavesSyncedData(
            data, cloudSyncEnabled: cloudSyncEnabled, switchedOn: switchedOn, synced: synced, pendingChecks: pendingChecks
        )
    }

    @Test("each kind TigerSync took stays on its backend; with TigerSync off, or the kind not taken, it does not")
    func syncedKindsStayOnTheBackend() {
        for kind in Self.kinds {
            #expect(Self.leaves(kind.data, switchedOn: kind.needs, synced: kind.needs))
            #expect(!Self.leaves(kind.data, cloudSyncEnabled: false))
            for category in kind.needs {
                #expect(!Self.leaves(kind.data, switchedOn: kind.needs, synced: kind.needs.subtracting([category])))
                #expect(!Self.leaves(kind.data, pendingChecks: [category]))
            }
        }
        #expect(Self.leaves(Held(holidays: true), switchedOn: [], synced: []))
        #expect(!Self.leaves(Held(holidays: true), cloudSyncEnabled: false))
        #expect(!Self.leaves(Held(localOnlyCourseNames: true)))
        #expect(!Self.leaves(Held()))
    }

    @Test("with every category synced and nothing on its way up, a sign-out loses nothing")
    func everythingSyncedLosesNothing() {
        #expect(!Self.deletes(Self.everything))
    }

    @Test("with TigerSync off, any of the user's data is lost")
    func tigerSyncOffLosesEveryKind() {
        for kind in Self.kinds {
            #expect(Self.deletes(kind.data, cloudSyncEnabled: false))
        }
        #expect(Self.deletes(Held(holidays: true), cloudSyncEnabled: false))
    }

    @Test("each kind needs its own categories switched on, taken by a sync and unchecked, and no others")
    func eachKindNeedsItsCategories() {
        for kind in Self.kinds {
            #expect(!Self.deletes(kind.data, switchedOn: kind.needs, synced: kind.needs))
            for category in kind.needs {
                let others = kind.needs.subtracting([category])
                #expect(Self.deletes(kind.data, switchedOn: others, synced: kind.needs))
                #expect(Self.deletes(kind.data, switchedOn: kind.needs, synced: others))
                #expect(Self.deletes(kind.data, switchedOn: kind.needs, synced: kind.needs, pendingChecks: [category]))
            }
        }
    }

    @Test("holiday choices need TigerSync alone")
    func holidaysNeedTigerSyncAlone() {
        #expect(!Self.deletes(Held(holidays: true), switchedOn: [], synced: []))
    }

    @Test("edits on their way up are lost however the switches stand")
    func unsentEditsAreLost() {
        #expect(Self.deletes(Held(), unsent: true))
    }

    @Test("with none of the user's data here, a sign-out loses nothing, TigerSync off too")
    func nothingHeldLosesNothing() {
        #expect(!Self.deletes(Held(), cloudSyncEnabled: false, switchedOn: [], synced: []))
    }

    @Test("a course name that never syncs is lost however the switches stand")
    func localOnlyNamesAreLost() {
        #expect(Self.deletes(Held(localOnlyCourseNames: true)))
    }

    @MainActor
    @Test("only a name on a course this device holds without a Moodle ID stays on this device")
    func namesWithoutAMoodleIdStayHere() {
        let handAdded = SDCourse(courseNo: "GE1010001", courseName: "Art", semester: "1151")
        let enrolled = SDCourse(courseNo: "CS1001301", courseName: "Algorithms", moodleIdNumber: "1151CS1001301")

        #expect(AppState.holdsLocalOnlyCourseNames(["GE1010001": ["zh": "Art"]], courses: [handAdded, enrolled]))
        #expect(!AppState.holdsLocalOnlyCourseNames(["CS1001301": ["zh": "Algo"]], courses: [handAdded, enrolled]))
        #expect(!AppState.holdsLocalOnlyCourseNames(["GE1010001": [:]], courses: [handAdded]))
        #expect(!AppState.holdsLocalOnlyCourseNames(["MA1010003": ["zh": "Gone"]], courses: [handAdded]))
    }
}

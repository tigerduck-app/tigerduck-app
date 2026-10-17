// What a sign-out deletes that TigerSync does not keep, which its confirmation names
// (https://github.com/tigerduck-app/tigerduck-app/issues/563).
import Testing
@testable import TigerDuck

struct SignOutUnsyncedDataTests {
    private typealias Held = AppState.SignOutData

    private static let categories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]

    /// Each kind of data, with the categories that must all keep it.
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
}

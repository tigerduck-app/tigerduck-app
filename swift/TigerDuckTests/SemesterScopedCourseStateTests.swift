import Foundation
import Testing
@testable import TigerDuck

struct CourseTombstoneTests {
    @Test func scopedKeyHidesOnlyItsSemester() {
        let set: Set<String> = [CourseTombstone.key(semester: "1151", courseNo: "CS1")]
        #expect(CourseTombstone.isHidden("CS1", semester: "1151", in: set))
        #expect(!CourseTombstone.isHidden("CS1", semester: "1142", in: set))
    }

    @Test func legacyBareEntryHidesEverywhereAndUnhideDropsBothShapes() {
        var set: Set<String> = ["CS1", CourseTombstone.key(semester: "1151", courseNo: "CS1")]
        #expect(CourseTombstone.isHidden("CS1", semester: "1142", in: set))
        #expect(CourseTombstone.unhide("CS1", semester: "1151", from: &set))
        #expect(set.isEmpty)
        #expect(!CourseTombstone.unhide("CS1", semester: "1151", from: &set))
    }

    @Test func resetDropsOneSemesterPlusLegacyEntries() {
        let set: Set<String> = ["CS1", "1151:CS2", "1142:CS3"]
        #expect(CourseTombstone.entries(resetting: "1151", in: set) == ["CS1", "1151:CS2"])
    }
}

struct CourseCardFontScaleTests {
    @Test func renderScaleAppliesTheBaselineMultiplier() {
        #expect(abs(CourseCardFontScale.renderScale(1.0) - 1.4) < 1e-9)
        #expect(abs(CourseCardFontScale.renderScale(9) - CourseCardFontScale.maximum * 1.4) < 1e-9)
    }

    @Test func legacyStoredValueIsRebasedOnce() {
        let suite = "CourseCardFontScaleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1.4, forKey: CourseCardFontScaleStore.legacyStorageKey)

        let store = CourseCardFontScaleStore(appGroupIdentifier: suite)
        #expect(abs(store.read() - 1.0) < 1e-9)
        #expect(defaults.object(forKey: CourseCardFontScaleStore.legacyStorageKey) == nil)
        #expect(abs(defaults.double(forKey: CourseCardFontScaleStore.storageKey) - 1.0) < 1e-9)
        // Second read is served from the new key, no re-migration.
        #expect(abs(store.read() - 1.0) < 1e-9)
    }
}

struct SyncStatusDotTests {
    @Test func summaryIsWorstKnownStateAndIgnoresGrey() {
        #expect(SyncStatusDot.summary(loadingState: .loaded, statuses: [.unknown, .ok]) == .ok)
        #expect(SyncStatusDot.summary(loadingState: .loaded, statuses: [.ok, .failed, .unknown]) == .failed)
        #expect(SyncStatusDot.summary(loadingState: .idle, statuses: [.unknown]) == .unknown)
        #expect(SyncStatusDot.summary(loadingState: .error("x"), statuses: [.ok]) == .failed)
    }
}

struct CourseTombstoneMigrationTests {
    @Test func legacyEntriesArePinnedToRostersThatCarryThem() {
        let rosters: [String: Set<String>] = ["1151": ["CS1", "CS2"], "1142": ["CS1"]]
        let migrated = Set(CourseTombstone.migratingLegacyEntries(["CS1", "CS9", "1142:CS3"], rosters: rosters))
        // CS1 is retaken, so it stays hidden in both terms; CS9 is unknown
        // and keeps its global form; scoped keys pass through untouched.
        #expect(migrated == ["1151:CS1", "1142:CS1", "CS9", "1142:CS3"])
    }
}

struct MisfiledServerRowTests {
    @MainActor
    @Test func rowWhoseMoodleIdNamesAnotherTermIsNotFiledHere() {
        #expect(!AppState.isFiled(["moodle_id": "1151CS1"], under: "1142"))
        #expect(AppState.isFiled(["moodle_id": "1142CS1"], under: "1142"))
        #expect(AppState.isFiled(["moodle_id": "114HCS1"], under: "114H"))
        // Moodle spells a summer term "114h", NTUST spells it "114H"; the
        // raw compare this replaced filed every summer row under another term.
        #expect(AppState.isFiled(["moodle_id": "114hCS1"], under: "114H"))
        #expect(!AppState.isFiled(["moodle_id": "113hCS1"], under: "114H"))
        // No semester-shaped Moodle id → nothing to contradict the filing.
        #expect(AppState.isFiled(["moodle_id": "moodle:42"], under: "1142"))
        #expect(AppState.isFiled([:], under: "1142"))
    }
}

struct ServerRowCourseMetadataTests {
    private static let row: [String: Any] = [
        "course_no": "GE1001",
        "course_name": "通識課",
        "credits": 0.5,
        "schedule_json": ["1": ["2", "3"]],
    ]

    /// A manual row that already saw QueryCourse keeps its dimension and
    /// duration when reconciliation rebuilds it to pick up a schedule. The
    /// sync payload carries neither, so defaulting would erase what this
    /// device knew — and for a term the portal no longer serves, nothing
    /// would ever fill it back in.
    @Test func rebuildingAnExistingRowKeepsItsDimensionAndDuration() {
        let course = AppState.course(fromServerRow: Self.row, courseNo: "GE1001",
                                     semester: "1151", name: "通識課",
                                     dimension: "C", allYear: "全學年")
        #expect(course.dimension == "C")
        #expect(course.allYear == "全學年")
        #expect(course.credits == 0.5)
        #expect(course.schedule[1] == ["2", "3"])
    }

    /// A row this device has never seen has no metadata to preserve: the
    /// backend does not send it, so both stay empty until QueryCourse runs.
    @Test func aFreshServerRowLeavesTheMetadataEmpty() {
        let course = AppState.course(fromServerRow: Self.row, courseNo: "GE1001",
                                     semester: "1151", name: nil)
        #expect(course.dimension.isEmpty)
        #expect(course.allYear.isEmpty)
    }
}

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

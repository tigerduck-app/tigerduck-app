import Defaults
import Foundation
import Testing
@testable import TigerDuck

struct SyncCategoryTests {
    @Test("Each category keeps the name Defaults stores and the backend's device switch carries")
    func rawValues() {
        #expect(SyncCategory.allCases.map(\.rawValue) == ["courses", "course_colors", "course_names", "assignments"])
    }

    @Test("A category set is stored as the array of names an earlier version wrote, and reads one back")
    func storedFormat() throws {
        let suiteName = "SyncCategoryTests-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let key = Defaults.Key<Set<SyncCategory>>("pendingConflictCategories", default: [], suite: suite)

        suite.set(["course_names", "courses"], forKey: key.name)
        #expect(Defaults[key] == [.courseNames, .courses])

        Defaults[key] = [.assignments]
        #expect(suite.array(forKey: key.name) as? [String] == ["assignments"])
    }
}

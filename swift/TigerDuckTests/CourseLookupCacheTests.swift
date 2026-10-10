import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseLookupCacheTests {
    @Test("a lookup is kept for 30 minutes per term, course and language, and fresh asks again")
    func lookupsAreKept() async throws {
        var calls = 0
        let search: () async throws -> [CourseSearchResult] = {
            calls += 1
            return []
        }
        let key = CourseLookupService.LookupKey(semester: "1151", courseNo: "T\(UUID().uuidString)", language: "zh")
        let start = Date()

        _ = try await CourseLookupService.kept(key, now: start, fresh: false, search: search)
        _ = try await CourseLookupService.kept(key, now: start + 29 * 60, fresh: false, search: search)
        #expect(calls == 1)

        _ = try await CourseLookupService.kept(key, now: start + 31 * 60, fresh: false, search: search)
        _ = try await CourseLookupService.kept(key, now: start + 31 * 60, fresh: true, search: search)
        #expect(calls == 3)

        let english = CourseLookupService.LookupKey(semester: "1151", courseNo: key.courseNo, language: "en")
        _ = try await CourseLookupService.kept(english, now: start + 31 * 60, fresh: false, search: search)
        #expect(calls == 4)
    }

    @Test("a failed lookup is not kept")
    func failuresAreNotKept() async throws {
        let key = CourseLookupService.LookupKey(semester: "1151", courseNo: "T\(UUID().uuidString)", language: "zh")
        let now = Date()
        await #expect(throws: URLError.self) {
            try await CourseLookupService.kept(key, now: now, fresh: false) { throw URLError(.timedOut) }
        }
        var calls = 0
        _ = try await CourseLookupService.kept(key, now: now, fresh: false) {
            calls += 1
            return []
        }
        #expect(calls == 1)
    }
}

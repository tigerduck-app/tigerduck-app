import Foundation
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MoodleEnrolledCoursesSharingTests {
    private final class Counter {
        var calls = 0
    }

    private static let course = MoodleEnrolledCourse(
        id: 1, fullname: "1151CS1 Course", shortname: "CS1", idnumber: "1151CS1",
        startDate: nil, endDate: nil
    )

    private func fetch(_ counter: Counter) -> () async throws -> [MoodleEnrolledCourse] {
        {
            counter.calls += 1
            try await Task.sleep(for: .milliseconds(50))
            return [Self.course]
        }
    }

    @Test("callers under one token share the request in flight")
    func concurrentCallersShareOneRequest() async throws {
        MoodleEnrolledCoursesService.dropSharedAnswer()
        let counter = Counter()
        let now = Date()
        async let first = MoodleEnrolledCoursesService.shared(token: "a", now: now, fetch: fetch(counter))
        async let second = MoodleEnrolledCoursesService.shared(token: "a", now: now, fetch: fetch(counter))
        _ = try await (first, second)
        #expect(counter.calls == 1)
    }

    @Test("an answer serves the same token for a minute, then is fetched again")
    func answerExpires() async throws {
        MoodleEnrolledCoursesService.dropSharedAnswer()
        let counter = Counter()
        let start = Date()
        _ = try await MoodleEnrolledCoursesService.shared(token: "a", now: start, fetch: fetch(counter))
        _ = try await MoodleEnrolledCoursesService.shared(token: "a", now: start + 30, fetch: fetch(counter))
        #expect(counter.calls == 1)
        _ = try await MoodleEnrolledCoursesService.shared(token: "a", now: start + 61, fetch: fetch(counter))
        #expect(counter.calls == 2)
    }

    @Test("another token never gets the kept answer")
    func answerIsKeyedByToken() async throws {
        MoodleEnrolledCoursesService.dropSharedAnswer()
        let counter = Counter()
        let now = Date()
        _ = try await MoodleEnrolledCoursesService.shared(token: "a", now: now, fetch: fetch(counter))
        _ = try await MoodleEnrolledCoursesService.shared(token: "b", now: now, fetch: fetch(counter))
        #expect(counter.calls == 2)
    }

    @Test("a failure is not kept, and a drop starts a new request")
    func failuresAndDropsRefetch() async throws {
        MoodleEnrolledCoursesService.dropSharedAnswer()
        let counter = Counter()
        let now = Date()
        await #expect(throws: URLError.self) {
            try await MoodleEnrolledCoursesService.shared(token: "a", now: now) {
                counter.calls += 1
                throw URLError(.timedOut)
            }
        }
        _ = try await MoodleEnrolledCoursesService.shared(token: "a", now: now, fetch: fetch(counter))
        MoodleEnrolledCoursesService.dropSharedAnswer()
        _ = try await MoodleEnrolledCoursesService.shared(token: "a", now: now, fetch: fetch(counter))
        #expect(counter.calls == 3)
    }
}

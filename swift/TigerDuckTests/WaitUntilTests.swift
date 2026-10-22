import Testing

struct WaitUntilTests {
    private final class ScriptedClock: Clock, @unchecked Sendable {
        typealias Duration = Swift.Duration

        struct Instant: InstantProtocol {
            var offset: Duration
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        }

        private(set) var now = Instant(offset: .zero)
        let minimumResolution = Duration.nanoseconds(1)
        private var sleeps: [Duration]

        init(sleeps: [Duration]) { self.sleeps = sleeps }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            now = now.advanced(by: sleeps.isEmpty ? now.duration(to: deadline) : sleeps.removeFirst())
        }
    }

    @Test func aWakeLatePastTheTimeoutLeavesTheWaitItsTime() async throws {
        let clock = ScriptedClock(sleeps: [.seconds(2)])
        var polls = 0
        try await waitUntil(timeout: .seconds(1), clock: clock) {
            polls += 1
            return polls == 3
        }
        #expect(polls == 3)
    }

    @Test func aWaitThatStaysStarvedStillGivesUp() async {
        let clock = ScriptedClock(sleeps: Array(repeating: .seconds(1), count: 100))
        var polls = 0
        await withKnownIssue {
            try await waitUntil(timeout: .seconds(1), clock: clock) {
                polls += 1
                return false
            }
        }
        #expect(polls == 11)
    }
}

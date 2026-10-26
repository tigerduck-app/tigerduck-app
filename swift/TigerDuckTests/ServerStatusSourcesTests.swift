import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ServerStatusSourcesTests {
    @MainActor
    private final class Indicator: LoadingIndicator {
        var loadingState: LoadingState = .idle {
            didSet { if loadingState == .loading { loadingStarts &+= 1 } }
        }
        private(set) var loadingStarts = 0
    }

    private struct Unreachable: Error {}

    private static func refresh(
        tracker: ServerStatusTracker,
        fetch: () async throws -> (report: ScoreReport, cachedAt: Date)
    ) async {
        await ScoreViewModel().refresh(
            for: "TEST\(UUID().uuidString)",
            generation: 1,
            isCurrent: { true },
            isReachable: { true },
            fetch: fetch,
            indicator: Indicator(),
            tracker: tracker
        )
    }

    @Test("The class table lists course selection, the score system, Moodle and TigerSync in that order")
    func classTableSources() {
        #expect(ServerKind.classTableSources == [.courseSelection, .scoreSystem, .moodle, .backend])
    }

    @Test("The transcript page names the score system, not course selection")
    func transcriptSources() {
        #expect(ServerKind.transcriptSources == [.scoreSystem])
    }

    @Test("A transcript fetch records the score system's answer and leaves course selection alone")
    func transcriptFetchRecordsTheScoreSystem() async {
        let answered = ServerStatusTracker()
        await Self.refresh(tracker: answered) { (ScoreReport.empty, Date()) }
        #expect(answered.status(for: .scoreSystem) == .ok)
        #expect(answered.status(for: .courseSelection) == .unknown)

        let failed = ServerStatusTracker()
        await Self.refresh(tracker: failed) { throw Unreachable() }
        #expect(failed.status(for: .scoreSystem) == .failed)
        #expect(failed.status(for: .courseSelection) == .unknown)
    }
}

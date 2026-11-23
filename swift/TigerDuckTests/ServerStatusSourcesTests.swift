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
            for: "TEST\(UUID().uuidString)", signIn: testSignIn,
            isReachable: { true },
            fetch: fetch,
            reports: ScoreReports(indicator: Indicator()),
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

    @Test("A real account's failure reads failed, with its note, also after a demo has ended")
    func aRealAccountsFailureReadsFailed() {
        let signIns = SignInSeries()
        signIns.startDemo()
        let tracker = ServerStatusTracker()
        tracker.showDemo(for: signIns.currentSignIn)
        signIns.end()

        for server in ServerKind.classTableSources { tracker.set(.failed, for: server, note: "timed out") }

        #expect(ServerKind.classTableSources.allSatisfy { tracker.status(for: $0) == .failed })
        #expect(ServerKind.classTableSources.allSatisfy { tracker.note(for: $0) == "timed out" })
    }

    @Test("A refresh without a network shows the offline error, and not in the demo, whose requests are refused")
    func theOfflineErrorIsNotTheDemos() {
        let real = Indicator()
        SchoolRefresh.showOffline(for: testSignIn, on: real)
        #expect(real.loadingState == .error(String(localized: "error_network_unavailable")))

        let demoSignIns = SignInSeries()
        demoSignIns.startDemo()
        let demo = Indicator()
        demo.loadingState = .error(String(localized: "error_network_unavailable"))
        SchoolRefresh.showOffline(for: demoSignIns.currentSignIn, on: demo)
        #expect(demo.loadingState == .loaded)
    }
}

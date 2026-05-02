import Foundation
import SwiftUI

@Observable
@MainActor
final class ScoreViewModel {

    enum RankingScope: String, CaseIterable, Identifiable {
        case semester
        case cumulative

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .semester:   return String(localized: "score_scope_semester")
            case .cumulative: return String(localized: "score_scope_cumulative")
            }
        }
    }

    // MARK: - State

    private(set) var report: ScoreReport = .empty
    private(set) var cachedAt: Date?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    var rankingScope: RankingScope = .semester

    /// Semesters the user manually collapsed. Lazy default rule: most recent
    /// semester expands, everything else collapses — persisted only during
    /// the view's lifetime so a fresh open re-focuses attention on "what
    /// changed last".
    var collapsedTerms: Set<String> = []

    // MARK: - Derived state

    /// Courses grouped by term, sorted newest-first.
    var groupedCourses: [(term: String, courses: [CourseGrade])] {
        let groups = Dictionary(grouping: report.courses, by: \.term)
        return groups
            .map { (term: $0.key, courses: $0.value.sorted { ($0.index ?? 0) < ($1.index ?? 0) }) }
            .sorted { $0.term > $1.term }
    }

    /// Ranking row matching a given term, if present. Used to annotate
    /// each semester header with GPA + rank metadata.
    func ranking(for term: String) -> SemesterRanking? {
        report.rankings.first { $0.term == term }
    }

    /// Rankings sorted chronologically for the trend chart.
    var rankingTrend: [SemesterRanking] {
        report.rankings.sorted { $0.term < $1.term }
    }

    var latestRanking: SemesterRanking? {
        rankingTrend.last
    }

    var hasContent: Bool {
        !report.courses.isEmpty || !report.rankings.isEmpty
    }

    // MARK: - Load / refresh

    func load(authService: AuthService) {
        guard let studentId = authService.storedStudentId else { return }

        // Instant cache paint — avoids a blank flash while the background
        // refresh resolves.
        if let cached = NTUSTScoreService.cachedScoreReport(studentId: studentId) {
            report = cached.report
            cachedAt = cached.cachedAt
            applyDefaultCollapseRule()
        }

        Task { await self.refresh(authService: authService, force: false) }
    }

    /// Coalesced fire-and-forget refresh. Designed for pull-to-refresh
    /// where the caller returns immediately (so UIRefreshControl dismisses
    /// its spinner) and the actual fetch continues on a detached Task;
    /// live progress lives in the top-right ``NetworkStatusOverlay`` instead.
    func triggerRefresh(authService: AuthService, force: Bool = true) {
        guard !isRefreshing else { return }
        // `Task { ... }` without an explicit actor inherits the
        // *enclosing* isolation; `refresh` mutates `manager.loadingState`
        // and `@Observable` properties that SwiftUI reads on main, so
        // pin the Task to MainActor explicitly (matches HomeViewModel /
        // ClassTableViewModel). Without this, resumption after the
        // network await may land on a background executor.
        Task { @MainActor [weak self] in
            await self?.refresh(authService: authService, force: force)
        }
    }

    func refresh(authService: AuthService, force: Bool = true) async {
        guard !isRefreshing else { return }
        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            errorMessage = String(localized: "common_not_logged_in")
            return
        }

        isRefreshing = true
        errorMessage = nil
        let manager = NTUSTSessionManager.shared
        manager.loadingState = .loading

        // Capture the auth generation that owns this fetch. If the user
        // logs out (or swaps accounts) before the network hop returns,
        // the persist guard below will reject the cache write so the
        // next user does not inherit the previous user's score report.
        let auth = authService
        let capturedGeneration = auth.loginGeneration
        do {
            let fresh = try await NTUSTScoreService.fetchScoreReport(
                session: manager.session,
                studentId: studentId,
                password: password,
                forceRefresh: force,
                persistGuard: { @Sendable [weak auth] in
                    auth?.loginGeneration == capturedGeneration
                }
            )
            report = fresh
            cachedAt = Date()
            applyDefaultCollapseRule()
            manager.loadingState = .loaded
        } catch {
            errorMessage = error.localizedDescription
            manager.loadingState = .error(error.localizedDescription)
        }

        isRefreshing = false
    }

    func toggleCollapse(term: String) {
        if collapsedTerms.contains(term) {
            collapsedTerms.remove(term)
        } else {
            collapsedTerms.insert(term)
        }
    }

    func isCollapsed(term: String) -> Bool {
        collapsedTerms.contains(term)
    }

    // MARK: - Private

    /// Collapse every term except the most recent the first time data lands.
    /// Re-running is idempotent when the user has already flipped a term.
    private func applyDefaultCollapseRule() {
        let terms = Set(report.courses.map(\.term))
        guard let latest = terms.max() else { return }
        // Only seed defaults once per fresh appearance; if the user has
        // already interacted we preserve their choices.
        guard collapsedTerms.isEmpty else {
            // Drop stale terms that no longer exist.
            collapsedTerms = collapsedTerms.intersection(terms)
            return
        }
        collapsedTerms = terms.filter { $0 != latest }
    }
}

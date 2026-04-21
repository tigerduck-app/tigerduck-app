import Foundation
import SwiftUI

@Observable
@MainActor
final class ScoreViewModel {

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all
        case graded
        case pending
        case exempted
        case withdrew

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all:      return "全部"
            case .graded:   return "已評定"
            case .pending:  return "成績未到"
            case .exempted: return "抵免"
            case .withdrew: return "退選"
            }
        }
    }

    enum RankingScope: String, CaseIterable, Identifiable {
        case semester
        case cumulative

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .semester:   return "學期"
            case .cumulative: return "累計"
            }
        }
    }

    // MARK: - State

    private(set) var report: ScoreReport = .empty
    private(set) var cachedAt: Date?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?

    var searchText: String = ""
    var statusFilter: StatusFilter = .all
    var rankingScope: RankingScope = .semester

    /// Semesters the user manually collapsed. Lazy default rule: most recent
    /// semester expands, everything else collapses — persisted only during
    /// the view's lifetime so a fresh open re-focuses attention on "what
    /// changed last".
    var collapsedTerms: Set<String> = []

    // MARK: - Derived state

    /// Courses grouped by term, sorted newest-first. Filtering respects
    /// search + status chip.
    var groupedCourses: [(term: String, courses: [CourseGrade])] {
        let filtered = filteredCourses()
        let groups = Dictionary(grouping: filtered, by: \.term)
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

    func refresh(authService: AuthService, force: Bool = true) async {
        guard !isRefreshing else { return }
        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            errorMessage = "未登入"
            return
        }

        isRefreshing = true
        errorMessage = nil
        let manager = NTUSTSessionManager.shared
        manager.loadingState = .loading

        do {
            let fresh = try await NTUSTScoreService.fetchScoreReport(
                session: manager.session,
                studentId: studentId,
                password: password,
                forceRefresh: force
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

    private func filteredCourses() -> [CourseGrade] {
        var result = report.courses

        switch statusFilter {
        case .all: break
        case .graded:   result = result.filter { $0.status == .graded }
        case .pending:  result = result.filter { $0.status == .pending }
        case .exempted: result = result.filter { $0.status == .exempted }
        case .withdrew: result = result.filter { $0.status == .withdrew }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.code.localizedCaseInsensitiveContains(query)
            }
        }
        return result
    }

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

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
    /// Whose report `report` is. Sign-out deletes the cached report but not this copy, which the
    /// next account would otherwise see until its own fetch landed.
    private var reportStudentId: String?
    /// When the report on screen was read from the school, which a cached report keeps.
    private(set) var cachedAt: Date?
    /// Derived once per report change instead of on every body pass —
    /// each semester header used to rebuild the whole GPA trend.
    private(set) var groupedCourses: [(term: String, courses: [CourseGrade])] = []
    private(set) var gpaTrend: [GPATrendPoint] = []
    private(set) var errorMessage: String?

    /// The sign-in the refresh in flight fetches for. Only a refresh for the same sign-in shares
    /// it, and an account change disowns it, so the next account never waits on the previous one.
    private var inFlightRefresh: RefreshOwner?
    var isRefreshing: Bool { inFlightRefresh != nil }

    private struct RefreshOwner: Equatable {
        let studentId: String
        let generation: Int
    }

    var rankingScope: RankingScope = .semester

    /// Semesters the user manually collapsed. Lazy default rule: most recent
    /// semester expands, everything else collapses — persisted only during
    /// the view's lifetime so a fresh open re-focuses attention on "what
    /// changed last".
    var collapsedTerms: Set<String> = []

    // MARK: - Derived state

    /// Replace the report and refresh everything derived from it.
    private func apply(_ newReport: ScoreReport, cachedAt date: Date) {
        report = newReport
        cachedAt = date
        groupedCourses = Dictionary(grouping: newReport.courses, by: \.term)
            .map { (term: $0.key, courses: $0.value.sorted { ($0.index ?? 0) < ($1.index ?? 0) }) }
            .sorted { $0.term > $1.term }
        gpaTrend = GPATrendPoint.trend(for: newReport)
        applyDefaultCollapseRule()
    }

    /// The trend point for `term`: its ranking once posted, the estimate
    /// from its grades until then. Annotates each semester header.
    func gpaPoint(for term: String) -> GPATrendPoint? {
        gpaTrend.first { $0.term == term }
    }

    var hasContent: Bool {
        !report.courses.isEmpty || !report.rankings.isEmpty
    }

    // MARK: - Load / refresh

    func load(authService: AuthService) {
        let studentId = authService.storedStudentId
        showCachedReport(for: studentId)
        guard studentId != nil else { return }

        Task { await self.refresh(authService: authService, force: false) }
    }

    /// Paints `studentId`'s cached report at once, avoiding a blank flash while the background
    /// refresh resolves, and empties the screen for nil, signed out. Skipped once its report is
    /// in: `load` runs on every tab appearance, and decoding the cache each time is wasted
    /// main-thread work.
    func showCachedReport(for studentId: String?) {
        switchAccount(to: studentId)
        guard let studentId, report == .empty,
              let cached = NTUSTScoreService.cachedScoreReport(studentId: studentId) else { return }
        apply(cached.report, cachedAt: cached.cachedAt)
    }

    private func switchAccount(to studentId: String?) {
        guard studentId != reportStudentId else { return }
        reportStudentId = studentId
        report = .empty
        cachedAt = nil
        groupedCourses = []
        gpaTrend = []
        collapsedTerms = []
        errorMessage = nil
        inFlightRefresh = nil
    }

    /// Coalesced fire-and-forget refresh. Designed for pull-to-refresh
    /// where the caller returns immediately (so UIRefreshControl dismisses
    /// its spinner) and the actual fetch continues on a detached Task;
    /// live progress lives in the top-right ``SyncStatusDot`` instead.
    func triggerRefresh(authService: AuthService, force: Bool = true) {
        guard !isRefreshing else { return }
        // Pinned to MainActor: `refresh` writes `manager.loadingState` and `@Observable` state that
        // SwiftUI reads on main, and a `Task` without an actor inherits the enclosing isolation, so
        // it could resume on a background executor after the network await.
        Task { @MainActor [weak self] in
            await self?.refresh(authService: authService, force: force)
        }
    }

    func refresh(authService: AuthService, force: Bool = true) async {
        // The auth generation that owns this fetch, read with the credentials before any await:
        // if the user logs out or swaps accounts before the fetch returns, the persist guard
        // rejects the cache write, so the next user does not inherit the previous user's report.
        let generation = authService.loginGeneration
        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            switchAccount(to: nil)
            errorMessage = String(localized: "common_not_signed_in")
            return
        }
        let session = NTUSTSessionManager.shared.session
        await refresh(
            for: studentId,
            generation: generation,
            isCurrent: { [weak authService] in authService?.loginGeneration == generation },
            isReachable: { await NetworkMonitor.shared.isReachable() },
            fetch: {
                try await NTUSTScoreService.fetchScoreReport(
                    session: session,
                    studentId: studentId,
                    password: password,
                    forceRefresh: force,
                    persistGuard: { @Sendable [weak authService] in
                        authService?.loginGeneration == generation
                    }
                )
            }
        )
    }

    /// The rest of `refresh(authService:force:)`, with the sign-in check, the reachability probe
    /// and the fetch passed in so a test can sign out while it waits.
    func refresh(
        for studentId: String,
        generation: Int,
        isCurrent: () -> Bool,
        isReachable: () async -> Bool,
        fetch: () async throws -> (report: ScoreReport, cachedAt: Date)
    ) async {
        switchAccount(to: studentId)
        let owner = RefreshOwner(studentId: studentId, generation: generation)
        guard inFlightRefresh != owner else { return }
        inFlightRefresh = owner
        defer { if inFlightRefresh == owner { inFlightRefresh = nil } }
        errorMessage = nil
        let manager = NTUSTSessionManager.shared
        // Captive-portal pre-flight: NTUSTScoreService rides the pinned SSO chain, so a portal
        // would surface as a confusing TLS error. Setting `manager.loadingState` as the other tabs'
        // bail paths do keeps ScoreView's SyncStatusDot in the same offline state as theirs.
        let reachable = await isReachable()
        // Signed out during the probe, the fetch would sign the departing account back in to the
        // school with these credentials; moved to another account, the screen no longer wants it.
        guard isCurrent(), inFlightRefresh == owner else { return }
        guard reachable else {
            let message = String(localized: "error_network_unavailable")
            errorMessage = message
            manager.loadingState = .error(message)
            return
        }
        manager.loadingState = .loading
        let starts = manager.loadingStarts

        let outcome: Result<(report: ScoreReport, cachedAt: Date), any Error>
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.courseSelection)
            #endif
            outcome = .success(try await fetch())
        } catch {
            outcome = .failure(error)
        }
        // Signed out, or the screen moved to another account, while the fetch ran: the answer
        // and its error belong to the previous account. The indicator stays with whatever has
        // started loading or reported an error since.
        guard isCurrent(), inFlightRefresh == owner else {
            if manager.loadingStarts == starts, manager.loadingState == .loading {
                manager.loadingState = .loaded
            }
            return
        }
        switch outcome {
        case .success(let fresh):
            apply(fresh.report, cachedAt: fresh.cachedAt)
            ServerStatusTracker.shared.set(.ok, for: .courseSelection)
            manager.loadingState = .loaded
        case .failure(let error):
            ServerStatusTracker.shared.set(.failed, for: .courseSelection)
            errorMessage = error.localizedDescription
            manager.loadingState = .error(error.localizedDescription)
        }
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
        // Compare numerically — string `.max()` is fine for fixed-width
        // term codes (e.g. "1142") but breaks on a stray malformed term
        // like "92" vs "1141". Falling back to lexical when ints fail.
        let latest = terms.max { lhs, rhs in
            if let l = Int(lhs), let r = Int(rhs) { return l < r }
            return lhs < rhs
        }
        guard let latest else { return }
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

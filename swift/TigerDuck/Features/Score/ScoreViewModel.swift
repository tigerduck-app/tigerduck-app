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

    private(set) var report: ScoreReport = .empty
    private var reportStudentId: String?
    private(set) var cachedAt: Date?
    private(set) var groupedCourses: [(term: String, courses: [CourseGrade])] = []
    private(set) var gpaTrend: [GPATrendPoint] = []
    private(set) var errorMessage: String?

    private var inFlightRefresh: RefreshOwner?
    var isRefreshing: Bool { inFlightRefresh != nil }

    private struct RefreshOwner: Equatable {
        let studentId: String
        let generation: Int
    }

    var rankingScope: RankingScope = .semester

    var collapsedTerms: Set<String> = []

    private func apply(_ newReport: ScoreReport, cachedAt date: Date) {
        report = newReport
        cachedAt = date
        groupedCourses = Dictionary(grouping: newReport.courses, by: \.term)
            .map { (term: $0.key, courses: $0.value.sorted { ($0.index ?? 0) < ($1.index ?? 0) }) }
            .sorted { $0.term > $1.term }
        gpaTrend = GPATrendPoint.trend(for: newReport)
        applyDefaultCollapseRule()
    }

    func gpaPoint(for term: String) -> GPATrendPoint? {
        gpaTrend.first { $0.term == term }
    }

    var hasContent: Bool {
        !report.courses.isEmpty || !report.rankings.isEmpty
    }

    func load(authService: AuthService) {
        let studentId = authService.storedStudentId
        showCachedReport(for: studentId)
        guard studentId != nil else { return }

        Task { await self.refresh(authService: authService, force: false) }
    }

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

    func triggerRefresh(authService: AuthService, force: Bool = true) {
        guard !isRefreshing else { return }
        Task { @MainActor [weak self] in
            await self?.refresh(authService: authService, force: force)
        }
    }

    func refresh(authService: AuthService, force: Bool = true) async {
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

    func refresh(
        for studentId: String,
        generation: Int,
        isCurrent: () -> Bool,
        isReachable: () async -> Bool,
        fetch: () async throws -> (report: ScoreReport, cachedAt: Date),
        indicator manager: LoadingIndicator = NTUSTSessionManager.shared
    ) async {
        switchAccount(to: studentId)
        let owner = RefreshOwner(studentId: studentId, generation: generation)
        guard inFlightRefresh != owner else { return }
        inFlightRefresh = owner
        defer { if inFlightRefresh == owner { inFlightRefresh = nil } }
        errorMessage = nil
        let reachable = await isReachable()
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

    private func applyDefaultCollapseRule() {
        let terms = Set(report.courses.map(\.term))
        let latest = terms.max { lhs, rhs in
            if let l = Int(lhs), let r = Int(rhs) { return l < r }
            return lhs < rhs
        }
        guard let latest else { return }
        guard collapsedTerms.isEmpty else {
            collapsedTerms = collapsedTerms.intersection(terms)
            return
        }
        collapsedTerms = terms.filter { $0 != latest }
    }
}

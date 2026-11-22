import Foundation

struct ScoreReports {
    var indicator: any LoadingIndicator = NTUSTSessionManager.shared
    var stored: (_ studentId: String) -> (report: ScoreReport, cachedAt: Date)? = {
        NTUSTScoreService.cachedScoreReport(studentId: $0)
    }

    func cached(studentId: String) -> (report: ScoreReport, cachedAt: Date)? {
        stored(studentId)
    }

    func fetch(
        studentId: String, password: String, force: Bool, for signIn: SignIn
    ) async throws -> (report: ScoreReport, cachedAt: Date) {
        try await NTUSTScoreService.fetchScoreReport(
            session: NTUSTSessionManager.shared.session,
            studentId: studentId,
            password: password,
            forceRefresh: force,
            for: signIn
        )
    }
}

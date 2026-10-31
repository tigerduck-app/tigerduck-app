import Foundation

/// The signed-in account's score report: the copy kept on the device, the fetch from the score
/// system, and the loading indicator a fetch drives.
struct ScoreReports {
    var indicator: any LoadingIndicator = NTUSTSessionManager.shared

    func cached(studentId: String) -> (report: ScoreReport, cachedAt: Date)? {
        NTUSTScoreService.cachedScoreReport(studentId: studentId)
    }

    func fetch(
        studentId: String, password: String, force: Bool, persistGuard: @escaping @Sendable () -> Bool
    ) async throws -> (report: ScoreReport, cachedAt: Date) {
        try await NTUSTScoreService.fetchScoreReport(
            session: NTUSTSessionManager.shared.session,
            studentId: studentId,
            password: password,
            forceRefresh: force,
            persistGuard: persistGuard
        )
    }
}

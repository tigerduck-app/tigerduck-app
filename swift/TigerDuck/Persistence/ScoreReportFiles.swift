import Foundation

/// The transcript of each student id signed in on this device, with the time it was fetched.
final class ScoreReportFiles: AccountScoped {
    static let shared = ScoreReportFiles()

    private let folders: CacheFolders

    init(folders: CacheFolders = .app) {
        self.folders = folders
    }

    static func forgetAccount(in storage: AccountStorage) {
        storage.folders.removeCacheFiles { $0.hasPrefix("score_report_") }
    }

    private struct CachedScoreReport: Codable {
        let report: ScoreReport
        let cachedAt: TimeInterval
    }

    func saveScoreReport(_ report: ScoreReport, studentId: String) {
        let envelope = CachedScoreReport(report: report, cachedAt: Date().timeIntervalSince1970)
        folders.cacheFiles.save(envelope, to: scoreReportFilename(studentId))
    }

    func loadScoreReport(studentId: String) -> (report: ScoreReport, cachedAt: Date)? {
        let envelope: CachedScoreReport? = folders.cacheFiles.load(scoreReportFilename(studentId))
        guard let envelope else { return nil }
        return (envelope.report, Date(timeIntervalSince1970: envelope.cachedAt))
    }

    func invalidateScoreReport(studentId: String) {
        try? FileManager.default.removeItem(at: folders.cacheFiles.url(scoreReportFilename(studentId)))
    }

    private func scoreReportFilename(_ studentId: String) -> String {
        "score_report_\(studentId).json"
    }
}

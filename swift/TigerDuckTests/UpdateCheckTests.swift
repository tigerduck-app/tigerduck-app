import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("App Store update check")
@MainActor
struct UpdateCheckTests {

    private final class ReportRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [any Error] = []

        var errors: [any Error] { lock.withLock { _errors } }

        func record(_ error: any Error, _ context: [String: String]) {
            lock.withLock { _errors.append(error) }
        }
    }

    private static func makeCoordinator(
        storeVersion: String,
        replies: Int = 1,
        reports: ReportRecorder = ReportRecorder()
    ) throws -> UpdateNotifyCoordinator {
        let bundleId = "test.\(UUID().uuidString)"
        let url = try #require(URL(
            string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(AppConstants.appStoreLookupStorefront)"
        ))
        let body = try JSONSerialization.data(withJSONObject: [
            "resultCount": 1,
            "results": [["version": storeVersion, "trackId": 6761084888]],
        ])
        for _ in 0..<replies {
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: body), for: url)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return UpdateNotifyCoordinator(
            bundleId: bundleId,
            session: URLSession(configuration: config),
            reportError: reports.record
        )
    }

    private static func checkManually(_ coordinator: UpdateNotifyCoordinator, times: Int = 1) async {
        await withExclusiveRealDefaults {
            let savedCheckAt = Defaults[.lastUpdateCheckAt]
            let savedReported = Defaults[.lastReportedUnparseableStoreVersion]
            defer {
                Defaults[.lastUpdateCheckAt] = savedCheckAt
                Defaults[.lastReportedUnparseableStoreVersion] = savedReported
            }
            Defaults[.lastReportedUnparseableStoreVersion] = nil
            for _ in 0..<times {
                await coordinator.checkManually()
            }
        }
    }

    /// App Store Connect takes the version as free text, and 2.2.0 went out
    /// as "v2.2.0". The prefix made the store version unparseable, which
    /// read as "not newer": no build was ever offered an update.
    @Test("a newer store version is offered, with or without a leading v",
          arguments: ["v99.0.0", "V99.0.0", "99.0.0"])
    func offersNewerStoreVersion(storeVersion: String) async throws {
        let coordinator = try Self.makeCoordinator(storeVersion: storeVersion)

        await Self.checkManually(coordinator)

        #expect(coordinator.pendingUpdate?.latestVersion == "99.0.0")
    }

    @Test("a v-prefixed store version that is not newer is up to date")
    func olderPrefixedStoreVersionIsUpToDate() async throws {
        let coordinator = try Self.makeCoordinator(storeVersion: "v0.0.1")

        await Self.checkManually(coordinator)

        #expect(coordinator.lastManualCheckResult == .upToDate)
        #expect(coordinator.pendingUpdate == nil)
    }

    @Test("an unreadable store version is a failed check, not up to date")
    func unreadableStoreVersionFailsTheCheck() async throws {
        let reports = ReportRecorder()
        let coordinator = try Self.makeCoordinator(storeVersion: "2.3.0-beta", reports: reports)

        await Self.checkManually(coordinator)

        #expect(coordinator.lastManualCheckResult == .failed)
        #expect(coordinator.pendingUpdate == nil)
        #expect(reports.errors.count == 1)
    }

    @Test("repeated manual checks report an unreadable store version once")
    func unreadableStoreVersionIsReportedOnce() async throws {
        let reports = ReportRecorder()
        let coordinator = try Self.makeCoordinator(storeVersion: "2.3.0-beta", replies: 3, reports: reports)

        await Self.checkManually(coordinator, times: 3)

        #expect(coordinator.lastManualCheckResult == .failed)
        #expect(reports.errors.count == 1)
    }
}

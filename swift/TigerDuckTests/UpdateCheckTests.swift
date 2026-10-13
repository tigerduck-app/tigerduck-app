// Bundle ids are per test because the stub is keyed by URL, which holds the id. Manual checks
// skip the 24h throttle, "Skip This Version" and "Later", so the reply alone decides. They still
// stamp real keys, so they run gated and restore them; a leftover stamp mutes background checks.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("App Store update check")
@MainActor
struct UpdateCheckTests {

    /// What the coordinator reported, in order.
    private final class ReportRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors: [any Error] = []

        var errors: [any Error] { lock.withLock { _errors } }

        func record(_ error: any Error, _ context: [String: String]) {
            lock.withLock { _errors.append(error) }
        }
    }

    /// A coordinator whose lookup is answered with `storeVersion`, exactly
    /// as typed into App Store Connect, once per `replies`. The stub answers
    /// the real lookup request, so its wire format is part of what is tested.
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

    /// Runs `times` manual checks in a row, starting from nothing reported.
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

    /// A store version the app cannot read is not evidence that the
    /// installed build is current.
    @Test("an unreadable store version is a failed check, not up to date")
    func unreadableStoreVersionFailsTheCheck() async throws {
        let reports = ReportRecorder()
        let coordinator = try Self.makeCoordinator(storeVersion: "2.3.0-beta", reports: reports)

        await Self.checkManually(coordinator)

        #expect(coordinator.lastManualCheckResult == .failed)
        #expect(coordinator.pendingUpdate == nil)
        #expect(reports.errors.count == 1)
    }

    /// Manual checks skip the 24h throttle, so the throttle alone would let
    /// every tap report the same unreadable version again.
    @Test("repeated manual checks report an unreadable store version once")
    func unreadableStoreVersionIsReportedOnce() async throws {
        let reports = ReportRecorder()
        let coordinator = try Self.makeCoordinator(storeVersion: "2.3.0-beta", replies: 3, reports: reports)

        await Self.checkManually(coordinator, times: 3)

        #expect(coordinator.lastManualCheckResult == .failed)
        #expect(reports.errors.count == 1)
    }
}

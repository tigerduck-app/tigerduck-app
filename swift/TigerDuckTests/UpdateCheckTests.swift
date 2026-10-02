// Pins what "Check for Updates" concludes from the App Store's answer.
//
// Driven through the real `UpdateNotifyCoordinator` and
// `AppStoreUpdateService` over `SettingsAPIStub`, so the lookup's wire
// format is part of what is tested. Each test uses a bundle id of its own:
// the stub is keyed by URL, and the bundle id is in the lookup's query.
//
// Every case is a manual check. That path ignores the 24h throttle, "Skip
// This Version" and the "Later" cooldown, so the outcome depends on the
// reply alone and not on what the test host has stored. It still stamps
// `lastUpdateCheckAt`, a real process-wide key, so each check runs inside
// the shared gate (`RealDefaultsGate.swift`) and puts the key back —
// otherwise a test run would silence the background check on the
// developer's simulator for a day.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("App Store update check")
@MainActor
struct UpdateCheckTests {

    /// A coordinator whose lookup is answered with `storeVersion`, exactly
    /// as typed into App Store Connect.
    private static func makeCoordinator(storeVersion: String) throws -> UpdateNotifyCoordinator {
        let bundleId = "test.\(UUID().uuidString)"
        let url = try #require(URL(
            string: "https://itunes.apple.com/lookup?bundleId=\(bundleId)&country=\(AppConstants.appStoreLookupStorefront)"
        ))
        let body = try JSONSerialization.data(withJSONObject: [
            "resultCount": 1,
            "results": [["version": storeVersion, "trackId": 6761084888]],
        ])
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: body), for: url)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return UpdateNotifyCoordinator(bundleId: bundleId, session: URLSession(configuration: config))
    }

    private static func checkManually(_ coordinator: UpdateNotifyCoordinator) async {
        await withExclusiveRealDefaults {
            let saved = Defaults[.lastUpdateCheckAt]
            defer { Defaults[.lastUpdateCheckAt] = saved }
            await coordinator.checkManually()
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
        let coordinator = try Self.makeCoordinator(storeVersion: "2.3.0-beta")

        await Self.checkManually(coordinator)

        #expect(coordinator.lastManualCheckResult == .failed)
        #expect(coordinator.pendingUpdate == nil)
    }
}

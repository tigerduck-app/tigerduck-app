import Foundation
import Testing
import UIKit
@testable import TigerDuck

/// A silent push, a Live Activity start or a Watch message can launch the app before the first
/// unlock after a restart, when `UserDefaults` reads as empty and a launch would take itself for a
/// fresh install (https://github.com/tigerduck-app/tigerduck-app/issues/680).
@MainActor
struct AfterFirstUnlockTests {
    @MainActor
    private final class Builds {
        var count = 0
        var ran: [Int] = []
    }

    private static func launch(hasUnlocked: Bool, center: NotificationCenter, builds: Builds) -> AfterFirstUnlock<Int> {
        let launch = AfterFirstUnlock(hasUnlocked: hasUnlocked, center: center) {
            builds.count += 1
            return builds.count
        }
        launch.whenBuilt { builds.ran.append($0) }
        return launch
    }

    @Test("A launch after the first unlock builds at once")
    func aLaunchAfterTheUnlockBuildsAtOnce() {
        let builds = Builds()

        let launch = Self.launch(hasUnlocked: true, center: NotificationCenter(), builds: builds)

        #expect(builds.count == 1)
        #expect(builds.ran == [1])
        withExtendedLifetime(launch) {}
    }

    @Test(
        "A launch before the first unlock builds nothing until the unlock or a return to the app, then once",
        arguments: [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
    )
    func aLaunchBeforeTheUnlockWaitsForIt(unlock: Notification.Name) {
        let center = NotificationCenter()
        let builds = Builds()

        let launch = Self.launch(hasUnlocked: false, center: center, builds: builds)
        #expect(builds.count == 0)
        #expect(builds.ran.isEmpty)

        center.post(name: unlock, object: nil)
        #expect(builds.count == 1)
        #expect(builds.ran == [1])

        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(builds.count == 1)
        #expect(builds.ran == [1])
        withExtendedLifetime(launch) {}
    }

    @Test("A scene that asks before the unlock notification arrives builds it, and the notification builds nothing more")
    func aSceneThatAsksFirstBuildsIt() {
        let center = NotificationCenter()
        let builds = Builds()
        let launch = Self.launch(hasUnlocked: false, center: center, builds: builds)

        #expect(launch.value == 1)
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

        #expect(builds.count == 1)
        #expect(builds.ran == [1])
        #expect(launch.value == 1)
    }

    @Test("Work asked for after the build runs at once with what was built")
    func workAfterTheBuildRunsAtOnce() {
        let builds = Builds()
        let launch = Self.launch(hasUnlocked: false, center: NotificationCenter(), builds: builds)
        _ = launch.value

        launch.whenBuilt { builds.ran.append($0 * 10) }

        #expect(builds.ran == [1, 10])
    }

    @Test("The probe reads a write that goes through as unlocked, again and again, and one that fails as locked")
    func theProbeReadsAFailedWriteAsLocked() throws {
        let folder = URL.temporaryDirectory.appending(path: "FirstUnlockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = folder.appending(path: "probe")

        #expect(FirstUnlock.hasHappened(probe: probe))
        #expect(FirstUnlock.hasHappened(probe: probe))
        // A simulator never locks, so a folder that is not there stands in for a class key that is not.
        #expect(!FirstUnlock.hasHappened(probe: folder.appending(path: "missing/probe")))
    }
}

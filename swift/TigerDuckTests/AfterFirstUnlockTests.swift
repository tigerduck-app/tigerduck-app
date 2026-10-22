import Defaults
import Foundation
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct AfterFirstUnlockTests {
    @MainActor
    private final class Builds {
        var count = 0
        var ran: [Int] = []
        var endedTheProcess = 0
    }

    private static func launch(
        hasUnlocked: Bool,
        storedDataReadsBack: Bool = true,
        center: NotificationCenter,
        builds: Builds
    ) -> AfterFirstUnlock<Int> {
        let launch = AfterFirstUnlock(
            hasUnlocked: hasUnlocked,
            storedDataReadsBack: { storedDataReadsBack },
            endProcess: { builds.endedTheProcess += 1 },
            center: center
        ) {
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

    @Test(
        "A held-back launch whose stored data still does not read back at the unlock builds nothing and ends the process",
        arguments: [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
    )
    func aHeldBackLaunchWhoseDataDoesNotReadBackEndsTheProcess(unlock: Notification.Name) {
        let center = NotificationCenter()
        let builds = Builds()
        let launch = Self.launch(hasUnlocked: false, storedDataReadsBack: false, center: center, builds: builds)

        center.post(name: unlock, object: nil)

        #expect(builds.count == 0)
        #expect(builds.ran.isEmpty)
        #expect(builds.endedTheProcess == 1)
        withExtendedLifetime(launch) {}
    }

    @Test("A launch after the first unlock builds without asking whether stored data reads back")
    func aLaunchAfterTheUnlockDoesNotAskForStoredData() {
        var asked = false
        var ended = false
        var built: Int?

        let launch = AfterFirstUnlock(
            hasUnlocked: true,
            storedDataReadsBack: {
                asked = true
                return false
            },
            endProcess: { ended = true },
            center: NotificationCenter()
        ) { 1 }
        launch.whenBuilt { built = $0 }

        #expect(built == 1)
        #expect(!asked)
        #expect(!ended)
    }

    @Test("Stored data reads back only with the installed flag an earlier launch set")
    func storedDataReadsBackByTheInstalledFlag() throws {
        let suite = "AfterFirstUnlockTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = AppConstants.UserDefaultsKeys.appHasBeenInstalled

        #expect(!FirstUnlock.storedDataReadsBack(defaults: defaults))
        defaults.set(false, forKey: key)
        #expect(!FirstUnlock.storedDataReadsBack(defaults: defaults))
        defaults.set(true, forKey: key)
        #expect(FirstUnlock.storedDataReadsBack(defaults: defaults))
    }

    @Test("The probe writes with the protection class that has no key before the first unlock")
    func theProbeAsksForTheFirstUnlockClass() {
        var options: Data.WritingOptions?

        #expect(FirstUnlock.hasHappened(probe: URL(filePath: "/unused")) { _, _, asked in options = asked })
        #expect(options == .completeFileProtectionUntilFirstUserAuthentication)
        #expect(!FirstUnlock.hasHappened(probe: URL(filePath: "/unused")) { _, _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
    }

    @Test("TigerDuck's launch before the first unlock writes no stored data")
    func theAppsHeldBackLaunchWritesNothing() async {
        let installed = AppConstants.UserDefaultsKeys.appHasBeenInstalled
        await withExclusiveRealDefaults {
            let savedInstalled = UserDefaults.standard.object(forKey: installed)
            let savedWhatsNew = Defaults[.lastShownWhatsNewVersion]
            let savedOnboarding = Defaults[.hasCompletedOnboarding]
            defer {
                UserDefaults.standard.set(savedInstalled, forKey: installed)
                Defaults[.lastShownWhatsNewVersion] = savedWhatsNew
                Defaults[.hasCompletedOnboarding] = savedOnboarding
            }
            UserDefaults.standard.removeObject(forKey: installed)
            Defaults[.lastShownWhatsNewVersion] = nil
            Defaults[.hasCompletedOnboarding] = false

            SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
                let launch = TigerDuckApp.makeLaunch(hasUnlocked: false, center: NotificationCenter())

                #expect(!UserDefaults.standard.bool(forKey: installed))
                #expect(Defaults[.lastShownWhatsNewVersion] == nil)
                withExtendedLifetime(launch) {}
            }
        }
    }

    @Test("TigerDuck's held-back launch with nothing stored ends the process at the unlock")
    func theAppsHeldBackLaunchEndsWithoutStoredData() async {
        let installed = AppConstants.UserDefaultsKeys.appHasBeenInstalled
        await withExclusiveRealDefaults {
            let savedInstalled = UserDefaults.standard.object(forKey: installed)
            let savedWhatsNew = Defaults[.lastShownWhatsNewVersion]
            let savedOnboarding = Defaults[.hasCompletedOnboarding]
            defer {
                UserDefaults.standard.set(savedInstalled, forKey: installed)
                Defaults[.lastShownWhatsNewVersion] = savedWhatsNew
                Defaults[.hasCompletedOnboarding] = savedOnboarding
            }
            UserDefaults.standard.removeObject(forKey: installed)
            Defaults[.lastShownWhatsNewVersion] = nil
            Defaults[.hasCompletedOnboarding] = false

            SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) {
                let center = NotificationCenter()
                var ended = 0
                let launch = TigerDuckApp.makeLaunch(hasUnlocked: false, center: center, endProcess: { ended += 1 })

                center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)

                #expect(ended == 1)
                #expect(!UserDefaults.standard.bool(forKey: installed))
                #expect(Defaults[.lastShownWhatsNewVersion] == nil)
                withExtendedLifetime(launch) {}
            }
        }
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

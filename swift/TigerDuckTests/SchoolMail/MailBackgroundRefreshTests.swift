#if os(iOS)
import BackgroundTasks
import Foundation
import Testing
@testable import TigerDuck

struct MailBackgroundRefreshTests {
    @Test func requestsTheMailRefreshTaskFifteenMinutesOut() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let request = MailBackgroundRefresh.makeRequest(now: now)
        #expect(request.identifier == "org.ntust.app.TigerDuck.mailRefresh")
        #expect(request.earliestBeginDate == now.addingTimeInterval(900))
    }

    @Test func foregroundChecksAreThrottledToOnceAMinute() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        #expect(MailForegroundCheck.isDue(lastCheck: nil, now: now))
        #expect(!MailForegroundCheck.isDue(lastCheck: now.addingTimeInterval(-30), now: now))
        #expect(MailForegroundCheck.isDue(lastCheck: now.addingTimeInterval(-60), now: now))
    }

    @Test func theAppDeclaresTheBackgroundTask() {
        let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(identifiers?.contains(MailConstants.backgroundTaskIdentifier) == true)
        #expect(modes?.contains("fetch") == true)
    }

    @Test func reschedulesOnlyWhileBackgroundChecksAreStillWanted() {
        #expect(MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: true, authFailed: false, notificationsDenied: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: false, notificationsEnabled: true, authFailed: false, notificationsDenied: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: false, authFailed: false, notificationsDenied: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: true, authFailed: true, notificationsDenied: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: false, signedIn: true, notificationsEnabled: true, authFailed: false, notificationsDenied: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: true, authFailed: false, notificationsDenied: true))
    }

    /// Before the first unlock after a restart, or in a process that started then and kept the
    /// empty copy, the preferences read as signed out, and a run that went by them would schedule
    /// no next one (https://github.com/tigerduck-app/tigerduck-app/issues/691).
    @Test func aRunWhileStoredDataDoesNotReadBackSchedulesTheNextAndChecksNothing() async throws {
        let suite = "MailBackgroundRefreshTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DefaultsMailPreferences(defaults: defaults)
        prefs.studentID = "B00000000"
        var scheduled = 0
        var checked = 0

        let succeeded = await MailBackgroundRefresh.refresh(
            storedDataReadsBack: { false },
            prefs: prefs,
            notificationsDenied: { false },
            schedule: { scheduled += 1 },
            check: {
                checked += 1
                return .skippedBusy
            }
        )

        #expect(!succeeded)
        #expect(scheduled == 1)
        #expect(checked == 0)
    }

    @Test func aRunOnReadablePreferencesOfASignedInAccountSchedulesTheNextAndChecks() async throws {
        let suite = "MailBackgroundRefreshTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DefaultsMailPreferences(defaults: defaults)
        prefs.studentID = "B00000000"
        var scheduled = 0
        var checked = 0

        let succeeded = await MailBackgroundRefresh.refresh(
            storedDataReadsBack: { true },
            prefs: prefs,
            notificationsDenied: { false },
            schedule: { scheduled += 1 },
            check: {
                checked += 1
                return .skippedBusy
            }
        )

        #expect(succeeded)
        #expect(scheduled == 1)
        #expect(checked == 1)
    }

    @Test func leavingTheForegroundDecidesFromTheLastPermissionRead() async {
        let denied = await MailNotificationPermission.isDenied()
        #expect(MailNotificationPermission.lastKnownDenied == denied)
        #expect(MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: true, authFailed: false,
            notificationsDenied: MailNotificationPermission.lastKnownDenied) == !denied)
    }

    @MainActor
    @Test func bootstrapWiresHooksThatDoTheRightThing() async {
        let center = RecordingNotificationCenter()
        let account = MailAccountManager(
            prefs: InMemoryMailPreferences(),
            credentials: MailCredentialStore(storage: InMemoryMailSecretStorage()),
            cache: MailCache(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)),
            clearCache: {}
        )
        SchoolMailBootstrap.install(account: account, notifier: MailNotifier(center: center))

        account.onSignedOut?()
        while center.removedAll < 1 { await Task.yield() }
        #expect(center.removedAll == 1)
        #expect(center.requests.isEmpty)

        account.onAuthFailed?()
        while center.requests.isEmpty { await Task.yield() }
        #expect(center.requests.count == 1)
        #expect(center.removedAll == 1)

        account.onNotificationsDisabled?()
        while center.removedAll < 2 { await Task.yield() }
        #expect(center.removedAll == 2)
    }
}
#endif

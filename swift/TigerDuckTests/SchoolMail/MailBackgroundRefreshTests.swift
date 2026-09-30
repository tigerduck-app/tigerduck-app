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

    /// Only while background checks are still wanted does a handled task ask for the next one —
    /// a signed-out or locked-out account must stop waking the app (controller ruling, task 12).
    @Test func reschedulesOnlyWhileBackgroundChecksAreStillWanted() {
        #expect(MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: true, authFailed: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: false, notificationsEnabled: true, authFailed: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: false, authFailed: false))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: true, signedIn: true, notificationsEnabled: true, authFailed: true))
        #expect(!MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: false, signedIn: true, notificationsEnabled: true, authFailed: false))
    }

    /// Installs onto its own `MailAccountManager` and `MailNotifier` — never
    /// `MailAccountManager.shared`, whose preferences are the app's real `UserDefaults` — and
    /// then *runs* the hooks. The previous version only asserted the five closures were
    /// non-nil, which held with every body replaced by `{}` or any two of them swapped.
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
        #expect(center.requests.isEmpty) // sign-out clears; it never posts

        account.onAuthFailed?()
        while center.requests.isEmpty { await Task.yield() }
        #expect(center.requests.count == 1) // the lock-out notice, not another clear
        #expect(center.removedAll == 1)

        account.onNotificationsDisabled?()
        while center.removedAll < 2 { await Task.yield() }
        #expect(center.removedAll == 2)
    }
}
#endif

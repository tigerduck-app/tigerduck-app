#if os(iOS)
import BackgroundTasks
import Foundation
import UserNotifications

/// School Mail's Background App Refresh (design doc §8.5). iOS decides when it runs —
/// often hours apart — so the UI never promises timing.
nonisolated enum MailBackgroundRefresh {
    /// Must run before `application(_:didFinishLaunchingWithOptions:)` returns.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: MailConstants.backgroundTaskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refresh)
        }
    }

    static func makeRequest(now: Date = Date()) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: MailConstants.backgroundTaskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(MailConstants.backgroundEarliestBegin)
        return request
    }

    /// Replaces any pending request. Fails silently where refresh is unavailable
    /// (simulator, Low Power Mode, the user switched Background App Refresh off).
    static func schedule() {
        try? BGTaskScheduler.shared.submit(makeRequest())
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: MailConstants.backgroundTaskIdentifier)
    }

    /// Whether a background task that just ran (or was about to) should submit the *next*
    /// request. Kept as a pure function of the account/feature state so it's testable without
    /// touching `BGTaskScheduler` or `UserDefaults`: only while background checks are still
    /// wanted — signed in, notifications on, not locked out by a rejected password, and the
    /// feature itself enabled — does the next refresh get scheduled. Otherwise a signed-out or
    /// locked-out account stops waking the app for nothing.
    static func shouldRescheduleAfterHandling(
        featureEnabled: Bool,
        signedIn: Bool,
        notificationsEnabled: Bool,
        authFailed: Bool
    ) -> Bool {
        featureEnabled && signedIn && notificationsEnabled && !authFailed
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // `DefaultsMailPreferences()` (nonisolated), not `MailAccountManager.shared`, which is
        // @MainActor and this callback isn't guaranteed to run on the main actor.
        let prefs = DefaultsMailPreferences()
        if shouldRescheduleAfterHandling(
            featureEnabled: SchoolMailAvailability.isEnabled,
            signedIn: prefs.studentID != nil,
            notificationsEnabled: prefs.notificationsEnabled,
            authFailed: prefs.authFailed
        ) {
            schedule()
        }
        let completion = TaskCompletion(task: task)
        let work = Task {
            let outcome = await MailChecker.shared.check(trigger: .backgroundTask)
            completion.finish(success: outcome.isSuccess)
        }
        task.expirationHandler = {
            work.cancel()
            completion.finish(success: false)
        }
    }

    /// Calls `setTaskCompleted` exactly once, whichever of expiry and completion is first.
    private final class TaskCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private let task: BGAppRefreshTask
        private var finished = false

        init(task: BGAppRefreshTask) { self.task = task }

        func finish(success: Bool) {
            lock.withLock {
                guard !finished else { return }
                finished = true
                task.setTaskCompleted(success: success)
            }
        }
    }
}

nonisolated enum MailForegroundCheck {
    static func isDue(lastCheck: Date?, now: Date, throttle: TimeInterval = MailConstants.foregroundCheckThrottle) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= throttle
    }

    /// Every return to the foreground, at most once a minute (§8.5).
    static func runIfDue(prefs: any MailPreferences = DefaultsMailPreferences(), now: Date = Date()) async {
        guard SchoolMailAvailability.isEnabled, isDue(lastCheck: prefs.lastCheckAt, now: now) else { return }
        _ = await MailChecker.shared.check(trigger: .foreground)
    }
}

nonisolated enum MailNotificationPermission {
    static func requestIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func isDenied() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }
}
#endif

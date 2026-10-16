#if os(iOS)
import BackgroundTasks
import Foundation
import os
import UserNotifications

/// School Mail's Background App Refresh. iOS decides when it runs, often hours apart, so the
/// UI never promises timing.
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

    /// Whether a background task that just ran, or was about to, should submit the next request:
    /// only while background checks are still wanted (signed in, notifications on and allowed by
    /// iOS, no rejected password, the feature enabled), so a signed-out or locked-out account
    /// stops waking the app for nothing. A pure function of that state, so it is testable without
    /// `BGTaskScheduler` or `UserDefaults`.
    static func shouldRescheduleAfterHandling(
        featureEnabled: Bool,
        signedIn: Bool,
        notificationsEnabled: Bool,
        authFailed: Bool,
        notificationsDenied: Bool
    ) -> Bool {
        featureEnabled && signedIn && notificationsEnabled && !authFailed && !notificationsDenied
    }

    private static func handle(_ task: BGAppRefreshTask) {
        let completion = TaskCompletion(task: task)
        let work = Task { completion.finish(success: await refresh()) }
        task.expirationHandler = {
            work.cancel()
            completion.finish(success: false)
        }
    }

    /// One background check. While stored data does not read back, as before the first unlock after
    /// a restart or in a process that started then, the preferences read as signed out and a check
    /// would schedule no next one, so it only schedules it
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/691). `prefs` is
    /// `DefaultsMailPreferences()`, not `MailAccountManager.shared`, which is @MainActor: this
    /// callback isn't guaranteed to run on the main actor.
    static func refresh(
        storedDataReadsBack: () -> Bool = { FirstUnlock.storedDataReadsBack() },
        prefs: any MailPreferences = DefaultsMailPreferences(),
        notificationsDenied: () async -> Bool = { await MailNotificationPermission.isDenied() },
        schedule: () -> Void = { MailBackgroundRefresh.schedule() },
        check: () async -> MailCheckOutcome = { await MailChecker.shared.check(trigger: .backgroundTask) }
    ) async -> Bool {
        guard storedDataReadsBack() else {
            schedule()
            return false
        }
        let denied = await notificationsDenied()
        if shouldRescheduleAfterHandling(
            featureEnabled: SchoolMailAvailability.isEnabled,
            signedIn: prefs.studentID != nil,
            notificationsEnabled: prefs.notificationsEnabled,
            authFailed: prefs.authFailed,
            notificationsDenied: denied
        ) {
            schedule()
        }
        return await check().isSuccess
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

    /// Every return to the foreground, at most once a minute.
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
        let denied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        lastRead.withLock { $0 = denied }
        return denied
    }

    /// What the last ``isDenied()`` found, `false` before any. Leaving the foreground decides
    /// from this: iOS can suspend the app before a fresh read returns, and no refresh is asked for.
    static var lastKnownDenied: Bool { lastRead.withLock { $0 } }

    private static let lastRead = OSAllocatedUnfairLock(initialState: false)
}
#endif

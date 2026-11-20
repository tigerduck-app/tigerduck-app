import Foundation
#if os(iOS)
import SafariServices
import UserNotifications
#endif

enum AccountSignOutCleanup {
    static func endSchoolSession(departing studentId: String?) {
        MoodleEnrolledCoursesService.dropSharedAnswer()
        ClassroomUsageService.shared.forget()
        NTUSTSessionManager.shared.cancelTasksAndForgetSignIn()
        CourseSelectionService.invalidateEnrolledCoursesCache(for: studentId)
    }

    static func clearAllCachedPages(
        cache: URLCache = .shared,
        clearBrowser: @MainActor () async -> Void = { await AccountSignOutCleanup.clearInAppBrowser() }
    ) async {
        cache.removeAllCachedResponses()
        await clearBrowser()
    }

    /// The browser's store answers through a system service, and one that never answers, as in
    /// the unit tests' host, must not hold up the next sign-in, which waits for the sign-out calls.
    static func clearInAppBrowser() async {
        #if os(iOS)
        let once = ResumeOnce()
        await withCheckedContinuation { continuation in
            once.continuation = continuation
            SFSafariViewController.DataStore.default.clearWebsiteData { Task { @MainActor in once.resume() } }
            Task {
                try? await AppClock.sleep(until: ContinuousClock.now + .seconds(5))
                once.resume()
            }
        }
        #endif
    }

    private final class ResumeOnce {
        var continuation: CheckedContinuation<Void, Never>?

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    #if os(iOS)
    static func removeAccountNotifications(from center: any DeliveredNotificationCenter) async {
        let identifiers = await center.deliveredNotificationDetails()
            .filter { $0.thread != MailConstants.notificationThread }
            .map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    #endif
}

#if os(iOS)
@MainActor
protocol DeliveredNotificationCenter {
    func deliveredNotificationDetails() async -> [(identifier: String, thread: String, userInfo: [AnyHashable: Any])]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension DeliveredNotificationCenter {
    /// iOS keeps a delivered notification until it is removed and has no expiry time for one.
    func removeExpiredReminders() async {
        let now = AppClock.now()
        let expired = await deliveredNotificationDetails()
            .filter { DeepLink.reminderDue(from: $0.userInfo).map { $0 <= now } ?? false }
            .map(\.identifier)
        removeDeliveredNotifications(withIdentifiers: expired)
    }
}

extension UNUserNotificationCenter: DeliveredNotificationCenter {
    func deliveredNotificationDetails() async -> [(identifier: String, thread: String, userInfo: [AnyHashable: Any])] {
        await deliveredNotifications().map {
            ($0.request.identifier, $0.request.content.threadIdentifier, $0.request.content.userInfo)
        }
    }
}
#endif

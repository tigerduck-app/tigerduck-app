import Foundation
#if os(iOS)
import SafariServices
import UserNotifications
#endif

/// What a sign-out clears beside the keychain: the school session and the answers kept for it,
/// the pages the URL cache and the in-app browser kept, and the account's delivered notifications.
enum AccountSignOutCleanup {
    static func endSchoolSession(departing studentId: String?) {
        MoodleEnrolledCoursesService.dropSharedAnswer()
        ClassroomUsageService.shared.forget()
        NTUSTSessionManager.shared.invalidateSession()
        CourseSelectionService.invalidateEnrolledCoursesCache(for: studentId)
    }

    /// Drops the school pages the shared URL cache kept and what the in-app browser kept from
    /// Moodle and NTUST, so the next account never sees them. Library and School Mail requests
    /// keep nothing in either; the browser's store goes whole, as a webmail page opened there does.
    static func forgetSchoolPages(
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
        let identifiers = await center.deliveredNotificationThreads()
            .filter { $0.thread != MailConstants.notificationThread }
            .map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    #endif
}

#if os(iOS)
@MainActor
protocol DeliveredNotificationCenter {
    func deliveredNotificationThreads() async -> [(identifier: String, thread: String)]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: DeliveredNotificationCenter {
    func deliveredNotificationThreads() async -> [(identifier: String, thread: String)] {
        await deliveredNotifications().map { ($0.request.identifier, $0.request.content.threadIdentifier) }
    }
}
#endif

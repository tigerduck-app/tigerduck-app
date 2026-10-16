import UIKit
import UserNotifications
import os

/// UIKit hook that captures the standard APNs device token.
///
/// SwiftUI's `@main App` doesn't expose `didRegisterForRemoteNotifications`
/// directly, so we bolt on a tiny `UIApplicationDelegate` via
/// `@UIApplicationDelegateAdaptor`. The single responsibility is to forward
/// the token to a `forwardTo` closure, which `TigerDuckApp` wires to the
/// shared `PushRegistrationService`.
final class PushAppDelegate: NSObject, UIApplicationDelegate, PushTokenSource {
    /// Set at launch and again in `TigerDuckApp`'s `.onAppear` through
    /// `PushCoordinator.bindTokenForwarding`, and called on the main thread with the raw token
    /// data. This delegate, the app and the coordinator live for the whole process, so the
    /// closure's weak capture of the coordinator never drops a token. APNs can deliver a token
    /// or error before it is set; `bufferedToken` and `bufferedError` hold it until the
    /// `didSet`s below replay it.
    var forwardToken: ((Data) -> Void)? {
        didSet {
            guard let forward = forwardToken, let token = bufferedToken else { return }
            bufferedToken = nil
            forward(token)
        }
    }
    /// Called when APNs registration fails (e.g. no entitlement, no network).
    /// Same app-lifetime contract as ``forwardToken``.
    var forwardError: ((Error) -> Void)? {
        didSet {
            guard let forward = forwardError, let error = bufferedError else { return }
            bufferedError = nil
            forward(error)
        }
    }

    private var bufferedToken: Data?
    private var bufferedError: Error?

    /// Owns the `UNUserNotificationCenterDelegate` for the lifetime of the
    /// app. `UNUserNotificationCenter` retains the delegate weakly, so this
    /// strong reference is what keeps it alive — without it the singleton
    /// would silently drop taps the moment ARC reclaimed the local variable
    /// set in `didFinishLaunchingWithOptions`.
    var notificationDelegate: NotificationDelegate?

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Delegate")

    /// Wiring that cannot wait for a scene, which `didFinishLaunching` runs once: iOS can launch the
    /// app in the background for a silent push or a Watch message, and then no `.onAppear` runs.
    /// `TigerDuckApp.init` sets it, as SwiftUI builds the app before it creates this delegate, and
    /// what it wires waits for the launch's ``AfterFirstUnlock`` build.
    static var launchWork: ((PushAppDelegate) -> Void)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        launchLogger.notice(
            "Launched in the background: \(application.applicationState == .background, privacy: .public), protected data available: \(application.isProtectedDataAvailable, privacy: .public)"
        )
        // Install the notification delegate before any push can arrive, so a tap
        // that cold-launches the app goes through `routeTap` instead of the OS
        // default open behaviour.
        let nd = NotificationDelegate()
        UNUserNotificationCenter.current().delegate = nd
        self.notificationDelegate = nd
        #if os(iOS)
        // School Mail's refresh task must be registered before launch finishes. Its checks decode
        // with the charset hook, which a held-back launch's School Mail bootstrap installs late.
        if SchoolMailAvailability.isEnabled {
            SchoolMailCharsetHook.install()
            MailBackgroundRefresh.register()
        }
        #endif
        Self.launchWork?(self)
        Self.launchWork = nil
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.info("APNs registered (len=\(deviceToken.count, privacy: .public))")
        if let forward = forwardToken {
            forward(deviceToken)
        } else {
            // `.onAppear` hasn't wired the forwarder yet — hold the token
            // until it does so the launch registration isn't lost.
            bufferedToken = deviceToken
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
        if let forward = forwardError {
            forward(error)
        } else {
            bufferedError = error
        }
    }

    var onSyncTrigger: (() async -> FullSyncOutcome)?

    /// Runs after a sync trigger's sync and before its answer. Once the push is answered iOS may
    /// suspend the app, so what the sync left on a timer, such as the widgets' reload, goes out here.
    var beforeAnsweringSyncTrigger: (@MainActor () -> Void)?

    /// iOS allows a background push 30 seconds to call its completion handler, and ends an app that
    /// takes longer (Apple's documentation for this delegate method).
    static let syncTriggerTimeLimit: Duration = .seconds(25)

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard userInfo["kind"] as? String == "sync_trigger", let onSyncTrigger else {
            completionHandler(.noData)
            return
        }
        logger.info("Silent sync trigger received")
        let beforeAnswering = beforeAnsweringSyncTrigger
        Self.run({
            let result = await onSyncTrigger().fetchResult
            beforeAnswering?()
            return result
        }, within: Self.syncTriggerTimeLimit, then: completionHandler)
    }

    /// Runs `work` and calls `completion` once with its result, or, when `limit` passes first,
    /// cancels it and calls `completion` with `.failed`. The limit runs off the main actor, which
    /// the work shares, so a busy main actor cannot hold the answer back.
    static func run(
        _ work: @escaping () async -> UIBackgroundFetchResult,
        within limit: Duration,
        then completion: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let answer = OSAllocatedUnfairLock<((UIBackgroundFetchResult) -> Void)?>(uncheckedState: completion)
        let finish: @Sendable (UIBackgroundFetchResult) -> Void = { result in
            // Cleared before the call, so whichever side comes second finds nothing to call.
            let call = answer.withLockUnchecked { stored in
                defer { stored = nil }
                return stored
            }
            call?(result)
        }
        let sync = Task { finish(await work()) }
        Task.detached {
            try? await Task.sleep(for: limit)
            sync.cancel()
            finish(.failed)
        }
    }
}

private extension FullSyncOutcome {
    var fetchResult: UIBackgroundFetchResult {
        switch self {
        case .synced: .newData
        case .skipped: .noData
        case .failed: .failed
        }
    }
}

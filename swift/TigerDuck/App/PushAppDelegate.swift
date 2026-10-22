import UIKit
import UserNotifications
import os

final class PushAppDelegate: NSObject, UIApplicationDelegate, PushTokenSource {
    var forwardToken: ((Data) -> Void)? {
        didSet {
            guard let forward = forwardToken, let token = bufferedToken else { return }
            bufferedToken = nil
            forward(token)
        }
    }
    var forwardError: ((Error) -> Void)? {
        didSet {
            guard let forward = forwardError, let error = bufferedError else { return }
            bufferedError = nil
            forward(error)
        }
    }

    private var bufferedToken: Data?
    private var bufferedError: Error?

    var notificationDelegate: NotificationDelegate?

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Delegate")

    static var launchWork: ((PushAppDelegate) -> Void)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        launchLogger.notice(
            "Launched in the background: \(application.applicationState == .background, privacy: .public), protected data available: \(application.isProtectedDataAvailable, privacy: .public)"
        )
        let nd = NotificationDelegate()
        UNUserNotificationCenter.current().delegate = nd
        self.notificationDelegate = nd
        #if os(iOS)
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

    var beforeAnsweringSyncTrigger: (@MainActor () -> Void)?

    var sendBeforeAnsweringSyncTrigger: (@MainActor (FullSyncOutcome) async -> Void)?

    static let syncTriggerTimeLimit: Duration = .seconds(25)

    static let syncTriggerSendLimit: Duration = syncTriggerTimeLimit - .seconds(3)

    var syncTriggerLimits = (answer: syncTriggerTimeLimit, send: syncTriggerSendLimit)

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
        Self.run(
            Self.syncTriggerWork(
                sync: onSyncTrigger,
                beforeAnswering: beforeAnsweringSyncTrigger,
                send: sendBeforeAnsweringSyncTrigger,
                sendDeadline: .now + syncTriggerLimits.send
            ),
            within: syncTriggerLimits.answer,
            then: completionHandler
        )
    }

    static func syncTriggerWork(
        sync: @escaping () async -> FullSyncOutcome,
        beforeAnswering: (@MainActor () -> Void)?,
        send: (@MainActor (FullSyncOutcome) async -> Void)?,
        sendDeadline: ContinuousClock.Instant
    ) -> () async -> UIBackgroundFetchResult {
        {
            let outcome = await sync()
            beforeAnswering?()
            if let send { await wait(for: { await send(outcome) }, until: sendDeadline) }
            return outcome.fetchResult
        }
    }

    static func wait(for step: @escaping @MainActor () async -> Void, until deadline: ContinuousClock.Instant) async {
        guard ContinuousClock.now < deadline else { return }
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: waiting)
            let stop: @Sendable () -> Void = {
                pending.withLock { stored in
                    defer { stored = nil }
                    return stored
                }?.resume()
            }
            let timer = Task.detached {
                try? await Task.sleep(until: deadline, clock: .continuous)
                stop()
            }
            Task {
                await step()
                timer.cancel()
                stop()
            }
        }
    }

    static func run(
        _ work: @escaping () async -> UIBackgroundFetchResult,
        within limit: Duration,
        appIsActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
        then completion: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let answer = OSAllocatedUnfairLock<((UIBackgroundFetchResult) -> Void)?>(uncheckedState: completion)
        let finish: @Sendable (UIBackgroundFetchResult) -> Void = { result in
            let call = answer.withLockUnchecked { stored in
                defer { stored = nil }
                return stored
            }
            call?(result)
        }
        let sync = Task { finish(await work()) }
        Task.detached {
            try? await Task.sleep(for: limit)
            finish(.failed)
            if await !appIsActive() { sync.cancel() }
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

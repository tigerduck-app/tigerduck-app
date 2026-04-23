import ActivityKit
import Defaults
import Foundation
import UIKit
import UserNotifications
import os

struct PushDiagnostic: Sendable {
    let enabled: Bool
    let isStarted: Bool
    let liveActivitiesEnabled: Bool
    let notificationAuthStatus: UNAuthorizationStatus
    let registration: PushRegistrationSnapshot
    let resolvedServerURL: URL
}

/// Owns the push-server lifecycle for the app.
///
/// AppState holds a single instance. Enabling/disabling flips the full
/// stack on or off idempotently so the settings toggle can toggle freely.
///
/// Responsibilities:
/// * Register for remote notifications on enable
/// * Wire the APNs device token into `PushRegistrationService`
/// * Start/stop the `PushTokenRelay` for Push-to-Start tokens
/// * Debounce `sync()` calls so bursts of data-change notifications
///   turn into one POST
@MainActor
final class PushCoordinator {
    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    private let registration: PushRegistrationService
    private let relay: PushTokenRelay
    let scheduleSync: ScheduleSyncService

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Coord")

    private var isStarted = false
    private var pendingSyncTask: Task<Void, Never>?

    init(
        identity: PushIdentity = .loadOrCreate(),
        apiClient: PushAPIClient? = nil
    ) {
        self.identity = identity
        let resolvedClient = apiClient ?? PushAPIClient(
            baseURL: Self.resolveServerURL(),
            sharedSecret: Self.resolveSharedSecret()
        )
        self.apiClient = resolvedClient
        self.registration = PushRegistrationService(
            identity: identity,
            apiClient: resolvedClient
        )
        self.relay = PushTokenRelay(registration: registration)
        self.scheduleSync = ScheduleSyncService(
            identity: identity,
            apiClient: resolvedClient
        )
    }

    // MARK: - Lifecycle

    /// Must be called from `TigerDuckApp.init` or `onAppear` so the
    /// `PushAppDelegate` can forward APNs tokens before they arrive.
    func bindTokenForwarding(_ appDelegate: PushAppDelegate) {
        appDelegate.forwardToken = { [weak self] data in
            guard let self else { return }
            Task { await self.registration.update(deviceToken: data) }
        }
        appDelegate.forwardError = { [weak self] error in
            guard let self else { return }
            Task { await self.registration.registrationFailed(error) }
        }
    }

    /// Enable the full push stack. Safe to call repeatedly.
    func enable() {
        guard !isStarted else { return }
        guard Defaults[.pushServerEnabled] else {
            logger.info("enable skipped — pushServerEnabled=false")
            return
        }
        isStarted = true
        logger.info("enabling push stack")

        // Request user-visible notification permission first so the user gets
        // an iOS system prompt as visible feedback that the toggle "did
        // something". PTS (Push-to-Start) tokens don't strictly require this
        // permission, but it unblocks standard-alert push later AND avoids
        // the silent-toggle-does-nothing UX.
        Task { @MainActor in
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            logger.info("notification authorization granted=\(granted, privacy: .public)")
            UIApplication.shared.registerForRemoteNotifications()
        }

        relay.start()
    }

    /// Returns the latest diagnostic snapshot for the settings view.
    func currentSnapshot() async -> PushDiagnostic {
        let reg = await registration.snapshot()
        let liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return PushDiagnostic(
            enabled: Defaults[.pushServerEnabled],
            isStarted: isStarted,
            liveActivitiesEnabled: liveActivitiesEnabled,
            notificationAuthStatus: notificationStatus,
            registration: reg,
            resolvedServerURL: Self.resolveServerURL()
        )
    }

    /// Disable and inform the server. Safe to call repeatedly.
    func disable() async {
        guard isStarted else { return }
        isStarted = false
        logger.info("disabling push stack")

        relay.stop()
        pendingSyncTask?.cancel()
        await registration.unregister()
    }

    // MARK: - Sync driver

    /// Schedules a debounced sync. Multiple rapid callers coalesce into one
    /// POST. If push is not enabled, no-op.
    func requestSync(
        debounceMs: Int = 400,
        inputsBuilder: @escaping @MainActor () -> ScheduleSyncService.Inputs
    ) {
        guard Defaults[.pushServerEnabled] else { return }
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard !Task.isCancelled else { return }
            let inputs = inputsBuilder()
            self?.scheduleSync.sync(inputs: inputs)
        }
    }

    // MARK: - Helpers

    static func resolveServerURL() -> URL {
        if let override = Defaults[.pushServerURLOverride],
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        return AppConstants.defaultPushServerURL
    }

    /// Read the shared secret from `Secrets.plist` (gitignored) bundled
    /// with the app. The `APIToken` key must match the server's
    /// `TIGERDUCK_API_SHARED_SECRET`. A missing file or empty value returns
    /// nil, which preserves the dev-friendly no-auth path.
    ///
    /// Falls back to the legacy Info.plist key so older builds keep
    /// working if an unrelated CI pipeline still injects there.
    static func resolveSharedSecret() -> String? {
        if let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let value = dict["APIToken"] as? String,
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "TigerDuckAPIToken") as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }
}

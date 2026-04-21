import Defaults
import Foundation
import UIKit
import os

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
        let resolvedClient = apiClient ?? PushAPIClient(baseURL: Self.resolveServerURL())
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

        UIApplication.shared.registerForRemoteNotifications()
        relay.start()
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

    private static func resolveServerURL() -> URL {
        if let override = Defaults[.pushServerURLOverride],
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        return AppConstants.defaultPushServerURL
    }
}

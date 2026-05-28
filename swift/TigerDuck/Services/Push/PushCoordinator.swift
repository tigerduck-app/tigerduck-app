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
    let userId: String
    let deviceId: String
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
    /// Exposed `internal` so AppState can call user-preference helpers
    /// (e.g. `updateServerPushOptOut`) without re-plumbing them through
    /// every layer. The actor still owns its own state — callers only see
    /// its async methods.
    let registration: PushRegistrationService
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
        // No `baseURL:` argument — `PushAPIClient` defaults to providers
        // that re-resolve the URL *and* shared secret through
        // `PushServerConfig` on every request, so a Debug build's runtime
        // endpoint override (Settings → Developer → API endpoint) takes
        // effect without an app relaunch and the auth header tracks
        // whichever backend the override points at.
        let resolvedClient = apiClient ?? PushAPIClient()
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
    ///
    /// - Parameter requestPermission: When `true`, the call also fires
    ///   the iOS system permission prompt — appropriate for the explicit
    ///   "turn on" Settings toggle, which needs visible feedback that the
    ///   toggle "did something". Pass `false` for the silent auto-enable
    ///   path that runs at every launch: it only calls
    ///   `registerForRemoteNotifications`, which is a no-op until the
    ///   user has granted permission elsewhere (typically onboarding).
    ///   Auto-enable must NOT prompt — that would land the system alert
    ///   on top of OnboardingView.
    func enable(requestPermission: Bool = false) {
        guard Defaults[.pushServerEnabled] else {
            logger.info("enable skipped — pushServerEnabled=false")
            return
        }
        // One-time stack bring-up: relay + `isStarted` flip happen on the
        // first call only. The permission/register block below intentionally
        // runs every time — auto-enable at launch (`requestPermission:
        // false`) lands first and sets `isStarted = true`, so a later
        // onboarding/Settings call with `requestPermission: true` must NOT
        // return early; otherwise the system alert never appears and APNs
        // is never asked to deliver a token, and the device never gets a
        // server registration row even with notifications granted.
        let firstStart = !isStarted
        if firstStart {
            isStarted = true
            relay.start()
        }
        logger.info("enabling push stack (firstStart=\(firstStart, privacy: .public), requestPermission=\(requestPermission, privacy: .public))")

        Task { @MainActor in
            if requestPermission {
                let granted = (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                logger.info("notification authorization granted=\(granted, privacy: .public)")
            }
            // registerForRemoteNotifications is safe to call regardless of
            // permission state — it returns an APNs token if authorized
            // and stays quiet otherwise. Calling it on every enable lets
            // a later permission grant (via onboarding or iOS Settings)
            // flow into the existing token-forwarding pipeline without
            // another explicit hook.
            UIApplication.shared.registerForRemoteNotifications()
        }
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
            resolvedServerURL: PushServerConfig.resolveServerURL(),
            userId: identity.userId,
            deviceId: identity.deviceId
        )
    }

    /// Disable and inform the server. Safe to call repeatedly.
    func disable() async {
        guard isStarted else { return }
        isStarted = false
        logger.info("disabling push stack")

        relay.stop()
        pendingSyncTask?.cancel()
        // Wait for any already-running debounced sync to finish before we
        // unregister, so a stale POST can't recreate state we just deleted.
        // `pendingSyncTask` only covers the debounce + builder; the actual
        // HTTP POST is owned by `ScheduleSyncService.inflight`, so we await
        // that separately — otherwise the POST can land *after* unregister.
        await pendingSyncTask?.value
        await scheduleSync.awaitInflight()
        await registration.unregister()
    }

    func registerLiveActivityUpdateToken(
        _ registrationPayload: LiveActivityUpdateTokenRegistration
    ) async {
        guard Defaults[.pushServerEnabled] else { return }
        await registration.registerLiveActivityUpdateToken(registrationPayload)
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
            // Don't run the inputs builder (which touches SwiftData / models)
            // while backgrounded — the system can suspend us mid-build.
            guard UIApplication.shared.applicationState != .background else { return }
            let inputs = inputsBuilder()
            self?.scheduleSync.sync(inputs: inputs)
        }
    }

    // MARK: - Build-time env sanity

    /// Crashes Debug builds at launch when the resolved server URL does not
    /// match the APNs environment baked into the binary (or each other).
    /// Compiles down to a no-op in Release builds — `assert` is stripped
    /// under `-O`, so end users never see this.
    ///
    /// Guards against the regression where someone flips `PushAPNsEnv` or
    /// `AppConstants.productionPushServerURL` without flipping the other,
    /// or seeds a stale UserDefaults override pointing the wrong way.
    nonisolated static func assertEnvConsistency() {
        let resolved = PushServerConfig.resolveServerURL()
        let host = resolved.host?.lowercased() ?? ""
        #if DEBUG
        let expectedEnv = "development"
        // Mirror the runtime override gate: any host `isOverrideAllowed`
        // accepts must also pass this assert, otherwise a Debug build
        // that saved an `api.tigerduck.app` apex or `*.api.tigerduck.app`
        // subdomain override would crash on next launch with a Keychain
        // value the user can't reach to clear. The apns_env mismatch when
        // pointing at prod is still real, but it surfaces as push failing
        // at registration time — not as a hard launch crash before any
        // UI renders.
        let hostOK = host == "localhost"
            || host == "127.0.0.1"
            || PushServerConfig.isPrivateIPv4(host)
            || PushServerConfig.isAllowedPublicHost(host)
        #else
        let expectedEnv = "production"
        let hostOK = host == "api.tigerduck.app"
        #endif
        assert(
            hostOK,
            "Push env mismatch: \(expectedEnv) build resolved to \(resolved)"
        )
        assert(
            PushAPNsEnv.resolvedForBuild == expectedEnv,
            "Push env mismatch: build is \(expectedEnv) but PushAPNsEnv = \(PushAPNsEnv.resolvedForBuild)"
        )
    }
}

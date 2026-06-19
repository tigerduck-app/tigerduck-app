import Defaults
import Foundation
#if canImport(UIKit)
import UIKit
#endif
import os

/// Orchestrates the `device ↔ server` binding.
///
/// Inputs feed in via `update(deviceToken:)` and `update(ptsToken:)` as iOS
/// hands them to us. Every time either token changes, we POST the full
/// registration record to the server. The server is tolerant of partial
/// state (either token may be nil) so early packets arrive safely before
/// both tokens are known.
struct PushRegistrationSnapshot: Sendable {
    let ptsTokenLength: Int
    let deviceTokenLength: Int
    let lastError: String?
    let lastRegisteredAt: Date?
}

/// APNs environment of the PTS token Apple issues for this build. Debug
/// builds use the sandbox (`api.sandbox.push.apple.com`); TestFlight and
/// App Store builds are issued production tokens. The server uses the
/// value we upload to select the correct APNs host, so it MUST match the
/// build configuration — never a constant string.
nonisolated enum PushAPNsEnv {
    #if DEBUG
    static let resolvedForBuild = "development"
    #else
    static let resolvedForBuild = "production"
    #endif
}

/// `device_class` value the iOS client reports. Drives operator-side
/// targeting (iPhone vs iPad vs Mac) without needing the backend to
/// re-parse build metadata.
nonisolated enum PushDeviceClass {
    // `@MainActor`: reading `UIDevice.current.userInterfaceIdiom` requires the
    // main actor. The only caller is `PushRegistrationService.init`'s default
    // argument, which is evaluated at the `@MainActor` `PushCoordinator.init`
    // call site, so the isolation requirement is always satisfied.
    @MainActor
    static var resolvedForBuild: String {
        #if os(macOS)
        return "mac"
        #else
        // `.mac` covers the "Designed for iPad" runtime on Apple Silicon,
        // where the iOS binary runs as a Mac app and the idiom reports
        // `.mac`. Falling through to "iphone" there would mis-target
        // operator pushes that filter on `device_class`.
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:   return "ipad"
        case .mac:   return "mac"
        case .phone: return "iphone"
        default:     return "iphone"
        }
        #endif
    }

    /// v3 `platform` value (server `UserDevicePlatform` enum) for a device
    /// class. The backend distinguishes iPhone from iPad via `ios`/`ipados`
    /// — operator targeting (and the portal's device tabs) rely on it, so we
    /// send the precise value rather than a flat "apple".
    static func platform(for deviceClass: String) -> String {
        switch deviceClass {
        case "ipad": return "ipados"
        case "mac":  return "macos"
        default:     return "ios"
        }
    }
}

actor PushRegistrationService {
    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    private let bundleId: String
    private let attrsType: String
    private let apnsEnv: String
    private let deviceClass: String
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Register")

    private var deviceTokenHex: String?
    private var ptsTokenHex: String?
    private var lastAttempt: Task<Void, Never>?
    private var lastError: String?
    private var lastRegisteredAt: Date?
    /// Most recently scheduled opt-out PATCH. New `updateServerPushOptOut`
    /// calls chain onto this task so PATCHes run in tap order, and the
    /// `apiClient → Defaults` pair always executes atomically — cancelling
    /// at the boundary would let a server-accepted change desync from the
    /// stored value.
    private var optOutPatchChain: Task<Void, Error>?
    #if os(iOS)
    private var pendingActivityRegistrations: [String: LiveActivityUpdateTokenRegistration] = [:]
    private var activity404Attempts: [String: Int] = [:]
    private let maxActivity404Attempts = 2
    private var activityRegistrationRetryTasks: [String: Task<Void, Never>] = [:]
    private var activityRegistrationAttempts: [String: Int] = [:]
    private let maxActivityRegistrationAttempts = 4
    #endif
    private let activityRegistrationBaseDelaySeconds: Double = 30
    private let activityRegistrationMaxDelaySeconds: Double = 600

    // Same retry shape for device registration: a transient 5xx leaving the
    // device permanently un-pushable was the original bug.
    private var deviceRegisterRetryTask: Task<Void, Never>?
    private var deviceRegisterAttempts: Int = 0
    private let maxDeviceRegisterAttempts = 4

    init(
        identity: PushIdentity,
        apiClient: PushAPIClient,
        bundleId: String = "org.ntust.app.TigerDuck",
        attrsType: String = "TigerDuckActivityAttributes",
        apnsEnv: String = PushAPNsEnv.resolvedForBuild,
        // No default: `PushDeviceClass.resolvedForBuild` is `@MainActor` (it
        // reads `UIDevice.current`), and an actor init's default-argument
        // expressions are evaluated in a nonisolated context. Callers pass it
        // from their own (MainActor) context instead.
        deviceClass: String
    ) {
        self.identity = identity
        self.apiClient = apiClient
        self.bundleId = bundleId
        self.attrsType = attrsType
        self.apnsEnv = apnsEnv
        self.deviceClass = deviceClass
    }

    // MARK: - Token intake

    func update(deviceToken: Data) async {
        let hex = deviceToken.hexEncodedString()
        guard hex != deviceTokenHex else { return }
        deviceTokenHex = hex
        logger.info("device APNs token updated (len=\(hex.count, privacy: .public))")
        await registerIfReady()
    }

    func update(ptsTokenHex hex: String) async {
        guard hex != ptsTokenHex else { return }
        ptsTokenHex = hex
        logger.info("PTS token updated (len=\(hex.count, privacy: .public))")
        await registerIfReady()
    }

    #if os(iOS)
    func registerLiveActivityUpdateToken(
        _ registration: LiveActivityUpdateTokenRegistration
    ) async {
        pendingActivityRegistrations[registration.activityId] = registration
        guard ptsTokenHex != nil else {
            await registerIfReady()
            return
        }
        await performActivityRegistration(registration, logger: logger)
    }
    #endif

    #if os(macOS)
    func registerPassiveDevice() async {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let request = PushAPI.DeviceRegisterRequest(
            client_device_id: identity.uuid,
            platform: PushDeviceClass.platform(for: deviceClass),
            device_name: nil,
            app_version: appVersion,
            os_version: ProcessInfo.processInfo.operatingSystemVersionString,
            push_token: nil
        )
        do {
            let response = try await apiClient.registerDevice(request)
            logger.info("registered passive macOS device device_id=\(response.device_id, privacy: .public)")
            noteSuccessfulRegistration()
        } catch {
            logger.error("passive device register failed: \(error.localizedDescription, privacy: .public)")
            noteRegistrationError(error)
        }
    }
    #endif

    func registrationFailed(_ error: Error) {
        lastError = "APNs register failed: \(error.localizedDescription)"
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    /// Called from the settings toggle. PATCHes the backend first; only
    /// flips the local pref after a 2xx so a transient failure doesn't
    /// leave local state pretending the server agrees. Throws on failure
    /// so the caller can roll back the Toggle UI and surface the error.
    /// The next `/devices/register` call also re-sends the value, so a
    /// later success backstops eventual consistency.
    ///
    /// Concurrent calls are serialised through `optOutPatchChain` so two
    /// rapid taps cannot interleave at the network suspension point. A
    /// previous version short-circuited with `Task.checkCancellation()`
    /// here, but cancellation can land *after* the server has already
    /// accepted the PATCH — skipping the local `Defaults` write in that
    /// window leaves Settings showing one value while the server holds
    /// another (operator pushes silently disabled while the toggle still
    /// reads enabled, and vice versa). Chaining instead lets every
    /// successfully-applied server change reach `Defaults`, and tap
    /// order is preserved because each task awaits its predecessor.
    func updateServerPushOptOut(_ optOut: Bool) async throws {
        let predecessor = optOutPatchChain
        let uuid = identity.uuid
        let apiClient = self.apiClient
        let logger = self.logger
        let task = Task<Void, Error> {
            // Tolerate predecessor failure — each tap's success is
            // independent of whether the previous one succeeded; we just
            // need its work to be done before ours starts.
            _ = try? await predecessor?.value
            do {
                _ = try await apiClient.updateDevicePreferences(
                    deviceId: uuid, serverPushEnabled: !optOut
                )
                await MainActor.run { Defaults[.serverPushUserOptOut] = optOut }
                logger.info("server push opt-out=\(optOut, privacy: .public) propagated")
            } catch {
                logger.error("server push opt-out PATCH failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        optOutPatchChain = task
        defer {
            // Don't pin a long-completed task as the chain head — clear
            // it unless a newer call has already taken our place.
            if optOutPatchChain == task {
                optOutPatchChain = nil
            }
        }
        try await task.value
    }

    /// Snapshot of internal state for UI display. Safe to call from any isolation.
    func snapshot() -> PushRegistrationSnapshot {
        PushRegistrationSnapshot(
            ptsTokenLength: ptsTokenHex?.count ?? 0,
            deviceTokenLength: deviceTokenHex?.count ?? 0,
            lastError: lastError,
            lastRegisteredAt: lastRegisteredAt
        )
    }

    // MARK: - Unregister

    /// Called when the user turns off server push or logs out.
    func unregister() async {
        do {
            try await apiClient.unregisterDevice(deviceId: identity.uuid)
            logger.info("unregistered device on server")
        } catch {
            logger.error("unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        deviceTokenHex = nil
        ptsTokenHex = nil
        #if os(iOS)
        pendingActivityRegistrations.removeAll()
        for task in activityRegistrationRetryTasks.values {
            task.cancel()
        }
        activityRegistrationRetryTasks.removeAll()
        activityRegistrationAttempts.removeAll()
        activity404Attempts.removeAll()
        #endif
        deviceRegisterRetryTask?.cancel()
        deviceRegisterRetryTask = nil
        deviceRegisterAttempts = 0
    }

    // MARK: - Internals

    /// Re-attempt registration after the auth state changes — the user just
    /// signed in and a v3 JWT is now available. Resets the give-up counter so
    /// a registration that exhausted its retries while unauthenticated gets a
    /// fresh chance, then fires immediately (subject to the PTS-token gate in
    /// `registerIfReady`).
    func retryAfterAuthChange() async {
        deviceRegisterAttempts = 0
        deviceRegisterRetryTask?.cancel()
        deviceRegisterRetryTask = nil
        #if os(iOS)
        await registerIfReady()
        #elseif os(macOS)
        await registerPassiveDevice()
        #endif
    }

    /// We upload as soon as the PTS token exists. Device token alone is not
    /// enough to start a Live Activity, and PTS is the Checkpoint-2/3 focus.
    /// The device token rides along for later standard-alert pushes.
    ///
    /// At app launch the PTS and APNs device tokens arrive within a few
    /// tens of ms of each other, so the naive "POST on every update"
    /// flow fired twice in a row — the first POST got cancelled mid-
    /// flight by the second `lastAttempt?.cancel()` and surfaced as the
    /// "register failed: 已取消" line in the logs. A 250ms debounce at
    /// the head of the Task is enough to coalesce both arrivals into
    /// one POST, and `CancellationError`s are silenced since they're
    /// the expected side-effect of a newer request winning.
    private func registerIfReady() async {
        #if os(iOS)
        guard ptsTokenHex != nil else { return }
        #endif

        lastAttempt?.cancel()
        let logger = self.logger
        lastAttempt = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            guard let self else { return }
            await self.performRegister(logger: logger)
        }
    }

    /// Re-reads the current tokens inside the actor and POSTs the
    /// registration. Split out so the debounce `Task` can call an
    /// actor-isolated method for fresh state instead of capturing
    /// stale `let`s from the enqueue site.
    private func performRegister(logger: Logger) async {
        guard let pts = ptsTokenHex else { return }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        do {
            let ptsRequest = PushAPI.DeviceRegisterRequest(
                client_device_id: identity.uuid,
                platform: PushDeviceClass.platform(for: deviceClass),
                device_name: nil,
                app_version: appVersion,
                os_version: nil,
                push_token: PushAPI.PushTokenIn(
                    provider: "apns",
                    token_kind: "push_to_start",
                    token_value: pts,
                    bundle_id: bundleId,
                    environment: apnsEnv,
                    scope_key: attrsType
                )
            )
            let ptsResponse = try await apiClient.registerDevice(ptsRequest)
            logger.info("registered device (PTS) device_id=\(ptsResponse.device_id, privacy: .public)")

            if let deviceToken = deviceTokenHex {
                let deviceTokenRequest = PushAPI.DeviceRegisterRequest(
                    client_device_id: identity.uuid,
                    platform: PushDeviceClass.platform(for: deviceClass),
                    device_name: nil,
                    app_version: appVersion,
                    os_version: nil,
                    push_token: PushAPI.PushTokenIn(
                        provider: "apns",
                        token_kind: "standard",
                        token_value: deviceToken,
                        bundle_id: bundleId,
                        environment: apnsEnv,
                        scope_key: ""
                    )
                )
                let tokenResponse = try await apiClient.registerDevice(deviceTokenRequest)
                logger.info("registered device (standard APNs) device_id=\(tokenResponse.device_id, privacy: .public)")
            }

            deviceRegisterRetryTask?.cancel()
            deviceRegisterRetryTask = nil
            deviceRegisterAttempts = 0
            noteSuccessfulRegistration()
            #if os(iOS)
            await flushPendingActivityRegistrations(logger: logger)
            #endif
        } catch is CancellationError {
            // Expected side-effect of debounce preempting an in-flight
            // request. Swallow silently so the logs stay clean.
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // URLSession surfaces cancellation this way on some paths.
        } catch {
            logger.error("register failed: \(error.localizedDescription, privacy: .public)")
            noteRegistrationError(error)
            scheduleDeviceRegisterRetry(logger: logger)
        }
    }

    private func scheduleDeviceRegisterRetry(logger: Logger) {
        deviceRegisterAttempts += 1
        guard deviceRegisterAttempts < maxDeviceRegisterAttempts else {
            logger.error("giving up on device register attempts=\(self.deviceRegisterAttempts, privacy: .public)")
            return
        }
        let delay = min(
            activityRegistrationBaseDelaySeconds * pow(3.0, Double(deviceRegisterAttempts - 1)),
            activityRegistrationMaxDelaySeconds
        )
        deviceRegisterRetryTask?.cancel()
        deviceRegisterRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.performRegister(logger: logger)
        }
    }

    private func noteSuccessfulRegistration() {
        lastRegisteredAt = Date()
        lastError = nil
        Task { @MainActor in
            Defaults[.pushLastRegistrationAt] = Date()
        }
    }

    private func noteRegistrationError(_ error: Error) {
        lastError = "register: \(error.localizedDescription)"
    }

    #if os(iOS)
    private func flushPendingActivityRegistrations(logger: Logger) async {
        for registration in Array(pendingActivityRegistrations.values) {
            await performActivityRegistration(registration, logger: logger)
        }
    }

    private func performActivityRegistration(
        _ registration: LiveActivityUpdateTokenRegistration,
        logger: Logger
    ) async {
        let snapshot = registration.snapshot
        // v3: encode `countdown_target` as ISO 8601 string (the server expects a
        // string field, not a nested object). Device identity comes from the JWT.
        let countdownISO: String?
        if let target = snapshot.countdownTarget {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            countdownISO = formatter.string(from: target)
        } else {
            countdownISO = nil
        }
        let request = PushAPI.LiveActivityRegisterV3Request(
            activity_id: registration.activityId,
            source_id: snapshot.sourceId,
            update_token_hex: registration.updateTokenHex,
            countdown_target: countdownISO,
            snapshot: snapshot,
            bundle_id: bundleId,
            environment: apnsEnv
        )
        do {
            let response = try await apiClient.registerLiveActivityToken(request)
            logger.info(
                "registered live activity token id=\(response.tokenId, privacy: .public)"
            )
            if pendingActivityRegistrations[registration.activityId]?.updateTokenHex == registration.updateTokenHex {
                pendingActivityRegistrations[registration.activityId] = nil
            }
            activityRegistrationRetryTasks[registration.activityId]?.cancel()
            activityRegistrationRetryTasks[registration.activityId] = nil
            activityRegistrationAttempts[registration.activityId] = nil
            activity404Attempts[registration.activityId] = nil
        } catch let error as PushAPIError {
            if case .httpStatus(404, _) = error {
                let activityId = registration.activityId
                let attempts = (activity404Attempts[activityId] ?? 0) + 1
                activity404Attempts[activityId] = attempts
                if attempts <= maxActivity404Attempts {
                    // Device row is missing server-side — re-register it; the
                    // success path will flush `pendingActivityRegistrations`
                    // immediately, no standalone retry needed.
                    await registerIfReady()
                    logger.error("live activity token register 404 attempt=\(attempts, privacy: .public) id=\(activityId, privacy: .public) — re-registering device")
                    return
                }
                // Exhausted 404 retries — fall through to exponential-backoff
                // so we don't spin unbounded.
                logger.error("live activity token register 404 exhausted attempts=\(attempts, privacy: .public) id=\(activityId, privacy: .public) — falling back to backoff retry")
            }
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .public)")
            scheduleActivityRegistrationRetry(registration, logger: logger)
        } catch {
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .public)")
            scheduleActivityRegistrationRetry(registration, logger: logger)
        }
    }

    /// Queue an exponential-backoff retry. Attempts counter and any in-flight
    /// retry task are keyed by activityId so a newer `registerLiveActivityUpdateToken`
    /// call (e.g. Apple rotated the update-token) can supersede the retry.
    private func scheduleActivityRegistrationRetry(
        _ registration: LiveActivityUpdateTokenRegistration,
        logger: Logger
    ) {
        let activityId = registration.activityId
        let attempt = (activityRegistrationAttempts[activityId] ?? 0) + 1
        activityRegistrationAttempts[activityId] = attempt
        guard attempt < maxActivityRegistrationAttempts else {
            logger.error(
                "giving up on live activity token register attempts=\(attempt, privacy: .public) id=\(activityId, privacy: .public)"
            )
            pendingActivityRegistrations[activityId] = nil
            activityRegistrationRetryTasks[activityId]?.cancel()
            activityRegistrationRetryTasks[activityId] = nil
            activityRegistrationAttempts[activityId] = nil
            return
        }
        let delay = min(
            activityRegistrationBaseDelaySeconds * pow(3.0, Double(attempt - 1)),
            activityRegistrationMaxDelaySeconds
        )
        activityRegistrationRetryTasks[activityId]?.cancel()
        activityRegistrationRetryTasks[activityId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.retryActivityRegistration(registration)
        }
    }

    private func retryActivityRegistration(
        _ registration: LiveActivityUpdateTokenRegistration
    ) async {
        // If a newer registration replaced this activity's pending entry
        // (Apple rotates update-tokens, or the client pushed a fresh
        // snapshot) the newer call's own success/retry cycle owns the
        // lifecycle from here — drop this retry.
        guard
            pendingActivityRegistrations[registration.activityId]?.updateTokenHex
                == registration.updateTokenHex
        else {
            return
        }
        await performActivityRegistration(registration, logger: logger)
    }
    #endif
}

import Defaults
import Foundation
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

actor PushRegistrationService {
    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    private let bundleId: String
    private let attrsType: String
    private let apnsEnv: String
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Register")

    private var deviceTokenHex: String?
    private var ptsTokenHex: String?
    private var lastAttempt: Task<Void, Never>?
    private var lastError: String?
    private var lastRegisteredAt: Date?
    private var pendingActivityRegistrations: [String: LiveActivityUpdateTokenRegistration] = [:]

    init(
        identity: PushIdentity,
        apiClient: PushAPIClient,
        bundleId: String = "org.ntust.app.TigerDuck",
        attrsType: String = "TigerDuckActivityAttributes",
        apnsEnv: String = PushAPNsEnv.resolvedForBuild
    ) {
        self.identity = identity
        self.apiClient = apiClient
        self.bundleId = bundleId
        self.attrsType = attrsType
        self.apnsEnv = apnsEnv
    }

    // MARK: - Token intake

    func update(deviceToken: Data) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
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

    func registrationFailed(_ error: Error) {
        lastError = "APNs register failed: \(error.localizedDescription)"
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
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
            try await apiClient.unregisterDevice(deviceId: identity.deviceId)
            logger.info("unregistered device on server")
        } catch {
            logger.error("unregister failed: \(error.localizedDescription, privacy: .public)")
        }
        deviceTokenHex = nil
        ptsTokenHex = nil
        pendingActivityRegistrations.removeAll()
    }

    // MARK: - Internals

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
        guard ptsTokenHex != nil else { return }

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
        let request = PushAPI.DeviceRegisterRequest(
            userId: identity.userId,
            deviceId: identity.deviceId,
            ptsTokenHex: pts,
            deviceTokenHex: deviceTokenHex,
            bundleId: bundleId,
            attrsType: attrsType,
            apnsEnv: apnsEnv
        )
        do {
            let response = try await apiClient.registerDevice(request)
            logger.info("registered device=\(response.deviceId, privacy: .public) user=\(response.userId, privacy: .public)")
            noteSuccessfulRegistration()
            await flushPendingActivityRegistrations(logger: logger)
        } catch is CancellationError {
            // Expected side-effect of debounce preempting an in-flight
            // request. Swallow silently so the logs stay clean.
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            // URLSession surfaces cancellation this way on some paths.
        } catch {
            logger.error("register failed: \(error.localizedDescription, privacy: .public)")
            noteRegistrationError(error)
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
        let request = PushAPI.LiveActivityTokenRegisterRequest(
            deviceId: identity.deviceId,
            activityId: registration.activityId,
            sourceId: snapshot.sourceId,
            scenario: snapshot.scenario,
            updateTokenHex: registration.updateTokenHex,
            countdownTarget: snapshot.countdownTarget,
            snapshot: snapshot
        )
        do {
            let response = try await apiClient.registerLiveActivityToken(request)
            logger.info(
                "registered live activity token id=\(response.activityId, privacy: .public)"
            )
            if pendingActivityRegistrations[registration.activityId]?.updateTokenHex == registration.updateTokenHex {
                pendingActivityRegistrations[registration.activityId] = nil
            }
        } catch let error as PushAPIError {
            if case .httpStatus(404, _) = error {
                await registerIfReady()
            }
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .public)")
        } catch {
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

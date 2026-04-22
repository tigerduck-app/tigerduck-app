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
    }

    // MARK: - Internals

    /// We upload as soon as the PTS token exists. Device token alone is not
    /// enough to start a Live Activity, and PTS is the Checkpoint-2/3 focus.
    /// The device token rides along for later standard-alert pushes.
    private func registerIfReady() async {
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

        lastAttempt?.cancel()
        let apiClient = self.apiClient
        let logger = self.logger
        lastAttempt = Task { [weak self] in
            do {
                let response = try await apiClient.registerDevice(request)
                logger.info("registered device=\(response.deviceId, privacy: .public) user=\(response.userId, privacy: .public)")
                await self?.noteSuccessfulRegistration()
            } catch {
                logger.error("register failed: \(error.localizedDescription, privacy: .public)")
                await self?.noteRegistrationError(error)
            }
        }
    }

    private func noteSuccessfulRegistration() async {
        lastRegisteredAt = Date()
        lastError = nil
        await MainActor.run {
            Defaults[.pushLastRegistrationAt] = Date()
        }
    }

    private func noteRegistrationError(_ error: Error) async {
        lastError = "register: \(error.localizedDescription)"
    }
}

import Defaults
import Foundation
import os

/// A request goes out for the sign-in current when it was asked for or its body was read.
nonisolated struct PushDeviceRequests: Sendable {
    let identity: PushIdentity
    let apiClient: PushAPIClient
    let signIns: SignInSeries
    let bundleId: String
    let attrsType: String
    let apnsEnv: String
    let deviceClass: String
    var keychain: PushIdentity.Store = .keychain
    let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Register")

    func pushTokens(device: String?, pts: String?) -> [PushAPI.PushTokenIn] {
        var tokens: [PushAPI.PushTokenIn] = []
        if let device {
            tokens.append(PushAPI.PushTokenIn(
                provider: "apns",
                token_kind: "standard",
                token_value: device,
                bundle_id: bundleId,
                environment: apnsEnv,
                scope_key: ""
            ))
        }
        if let pts {
            tokens.append(PushAPI.PushTokenIn(
                provider: "apns",
                token_kind: "push_to_start",
                token_value: pts,
                bundle_id: bundleId,
                environment: apnsEnv,
                scope_key: attrsType
            ))
        }
        return tokens
    }

    func announce(deviceToken: String?) async {
        do {
            try await sendAnonymous(deviceToken: deviceToken, serverPushEnabled: !Defaults[.serverPushUserOptOut])
        } catch is CancellationError {
        } catch {
            logger.error("device announce failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Whether a request went out.
    @discardableResult
    func sendAnonymous(deviceToken: String?, serverPushEnabled: Bool) async throws -> Bool {
        guard identity.isLoaded else { return false }
        do {
            try await apiClient.registerAnonymousDevice(
                PushAPI.AnonymousDeviceRequest(
                    device_id: identity.uuid,
                    platform: "apple",
                    device_class: deviceClass,
                    push_token: deviceToken,
                    bundle_id: bundleId,
                    server_push_enabled: serverPushEnabled,
                    device_secret: identity.secret
                )
            )
        } catch let error as PushAPIError where error.refusesDeviceSecret {
            Defaults[.pushDeviceSecretRefused] = true
            throw error
        }
        // The backend answers a request with both a secret and a token only after binding the secret.
        if identity.secret != nil, deviceToken?.isEmpty == false, Defaults[.pushDeviceSecretRefused] {
            Defaults[.pushDeviceSecretRefused] = false
        }
        return true
    }

    func register(_ tokens: [PushAPI.PushTokenIn]) async throws {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let signIn = signIns.currentSignIn
        let cloudSync = Defaults[.cloudSyncEnabled]
        logger.info("[register] cloud_sync_enabled=\(cloudSync, privacy: .public)")
        for token in tokens {
            let request = try registerRequest(pushToken: token, appVersion: appVersion, cloudSync: cloudSync)
            let response = try await apiClient.registerDevice(request, for: signIn)
            logger.info("registered device (\(token.token_kind, privacy: .public)) device_id=\(response.device_id, privacy: .private)")
        }
    }

    #if os(macOS)
    func registerPassive() async throws {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let signIn = signIns.currentSignIn
        let request = try registerRequest(pushToken: nil, appVersion: appVersion, cloudSync: Defaults[.cloudSyncEnabled])
        let response = try await apiClient.registerDevice(request, for: signIn)
        logger.info("registered passive macOS device device_id=\(response.device_id, privacy: .private)")
    }
    #endif

    private func registerRequest(
        pushToken: PushAPI.PushTokenIn?, appVersion: String?, cloudSync: Bool
    ) throws -> PushAPI.DeviceRegisterRequest {
        try PushAPI.DeviceRegisterRequest(
            client_device_id: identity.storedUUID(),
            platform: PushDeviceClass.platform(for: deviceClass),
            device_class: deviceClass,
            app_version: appVersion,
            os_version: { let v = ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }(),
            device_model: PushDeviceModel.current,
            locale: PushRegistrationService.renderedLanguageTag,
            push_token: pushToken,
            cloud_sync_enabled: cloudSync,
            bulletin_push_enabled: Defaults[.bulletinPushEnabled],
            server_push_enabled: !Defaults[.serverPushUserOptOut],
            device_secret: identity.secret
        )
    }

    func unregister(at baseURL: URL?) async -> Bool {
        do {
            try await apiClient.unregisterDevice(deviceId: identity.storedUUID(), at: baseURL)
            logger.info("unregistered device on server")
            return true
        } catch let error as PushAPIError where error.code == "device_not_found" {
            logger.info("device already unregistered on server")
            return true
        } catch {
            logger.error("unregister failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    #if os(iOS)
    func registerActivity(_ registration: LiveActivityUpdateTokenRegistration) async throws {
        let snapshot = registration.snapshot
        let countdownISO: String?
        if let target = registration.countdownTargetRealTime {
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
        let response = try await apiClient.registerLiveActivityToken(request, for: signIns.currentSignIn)
        logger.info(
            "registered live activity token id=\(response.tokenId, privacy: .private)"
        )
    }
    #endif
}

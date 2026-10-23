import Defaults
import Foundation
#if canImport(UIKit)
import UIKit
#endif
import os

struct PushRegistrationSnapshot: Sendable {
    let ptsTokenLength: Int
    let deviceTokenLength: Int
    let lastError: String?
    let lastAttemptFoundNoSession: Bool
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

/// The hardware model this device reports to the backend, for support work
/// in the portal: the machine identifier ("iPhone17,3", "iPad16,3",
/// "Mac15,3"). Apple exposes no marketing name. A simulator reports the
/// identifier of the device it simulates.
nonisolated enum PushDeviceModel {
    static let current: String? = {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        #else
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        #endif
    }()
}

nonisolated enum PushDeviceClass {
    // `@MainActor`: reading `UIDevice.current.userInterfaceIdiom` requires the
    // main actor.
    @MainActor
    static var resolvedForBuild: String {
        #if os(macOS)
        return "mac"
        #else
        // An iOS binary running on an Apple Silicon Mac ("Designed for iPad")
        // reports `.mac`. Falling through to "iphone" there would mis-target
        // operator pushes that filter on `device_class`.
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:   return "ipad"
        case .mac:   return "mac"
        case .phone: return "iphone"
        default:     return "iphone"
        }
        #endif
    }

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
    private var lastAttemptFoundNoSession = false
    private var lastRegisteredAt: Date?
    private var optOutPatchChain: Task<Void, Error>?
    private var bulletinPatchChain: Task<Void, Error>?
    private var syncPreferencesPatchChain: Task<Void, Never>?
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

    private var deviceRegisterRetryTask: Task<Void, Never>?
    private var deviceRegisterAttempts: Int = 0
    private let maxDeviceRegisterAttempts = 4
    #if os(macOS)
    private var passiveRegistrationsRunning = 0
    #endif
    private var registrationsInFlight = 0
    private var cloudSyncPatchesWaiting: [CheckedContinuation<Void, Never>] = []
    private var registerAgainIfRunningFails = false

    private let debounceSleep: @Sendable (Duration) async -> Void
    private let retrySleep: @Sendable (Duration) async -> Void

    init(
        identity: PushIdentity,
        apiClient: PushAPIClient,
        bundleId: String = "org.ntust.app.TigerDuck",
        attrsType: String = "TigerDuckActivityAttributes",
        apnsEnv: String = PushAPNsEnv.resolvedForBuild,
        // No default: `PushDeviceClass.resolvedForBuild` is `@MainActor`, and
        // an actor init evaluates default arguments in a nonisolated context.
        // Callers pass it from their own main-actor context.
        deviceClass: String,
        debounceSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        retrySleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.identity = identity
        self.apiClient = apiClient
        self.bundleId = bundleId
        self.attrsType = attrsType
        self.apnsEnv = apnsEnv
        self.deviceClass = deviceClass
        self.debounceSleep = debounceSleep
        self.retrySleep = retrySleep
    }

    // MARK: - Locale

    /// The language the app is rendering, not the device's region setting:
    /// `preferredLocalizations` reflects what actually resolved against the
    /// bundle, so the server's copy matches what the user sees on screen.
    static var currentLocaleTag: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

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
        guard hasRegistrableToken else {
            await registerIfReady()
            return
        }
        await performActivityRegistration(registration, logger: logger)
    }
    #endif

    #if os(macOS)
    func registerPassiveDevice() async {
        passiveRegistrationsRunning += 1
        defer {
            passiveRegistrationsRunning -= 1
            releaseCloudSyncPatchesIfIdle()
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let request = PushAPI.DeviceRegisterRequest(
            client_device_id: identity.uuid,
            platform: PushDeviceClass.platform(for: deviceClass),
            device_class: deviceClass,
            app_version: appVersion,
            os_version: { let v = ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }(),
            device_model: PushDeviceModel.current,
            locale: Self.currentLocaleTag,
            push_token: nil,
            cloud_sync_enabled: Defaults[.cloudSyncEnabled],
            bulletin_push_enabled: Defaults[.bulletinPushEnabled],
            server_push_enabled: !Defaults[.serverPushUserOptOut]
        )
        do {
            let response = try await apiClient.registerDevice(request)
            logger.info("registered passive macOS device device_id=\(response.device_id, privacy: .private)")
            noteSuccessfulRegistration()
            await resendSyncPreferencesIfPending()
        } catch {
            logger.error("passive device register failed: \(error.localizedDescription, privacy: .private)")
            noteRegistrationError(error)
        }
    }
    #endif

    func registrationFailed(_ error: Error) {
        lastError = "APNs register failed: \(error.localizedDescription)"
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
    }

    func uploadHolidayOverride(holidayID: Int, notify: Bool) async throws {
        try await apiClient.putHolidayOverride(holidayID: holidayID, notify: notify)
    }

    func updateServerPushOptOut(_ optOut: Bool) async throws {
        let predecessor = optOutPatchChain
        let uuid = identity.uuid
        let apiClient = self.apiClient
        let logger = self.logger
        let deviceClass = self.deviceClass
        let bundleId = self.bundleId
        let tokenHex = self.deviceTokenHex
        let task = Task<Void, Error> {
            _ = try? await predecessor?.value
            do {
                try await apiClient.registerAnonymousDevice(
                    PushAPI.AnonymousDeviceRequest(
                        device_id: uuid,
                        platform: "apple",
                        device_class: deviceClass,
                        push_token: tokenHex,
                        bundle_id: bundleId,
                        server_push_enabled: !optOut
                    )
                )
                if await apiClient.hasAuthSession() {
                    _ = try await apiClient.updateDevicePreferences(
                        deviceId: uuid, serverPushEnabled: !optOut
                    )
                }
                await MainActor.run { Defaults[.serverPushUserOptOut] = optOut }
                logger.info("server push opt-out=\(optOut, privacy: .public) propagated")
            } catch {
                logger.error("server push opt-out did not propagate: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
        optOutPatchChain = task
        defer {
            if optOutPatchChain == task {
                optOutPatchChain = nil
            }
        }
        try await task.value
    }

    func updateBulletinPushEnabled(_ enabled: Bool) async throws {
        let predecessor = bulletinPatchChain
        let uuid = identity.uuid
        let apiClient = self.apiClient
        let logger = self.logger
        let task = Task<Void, Error> {
            _ = try? await predecessor?.value
            do {
                let response = try await apiClient.updateDevicePreferences(
                    deviceId: uuid, bulletinPushEnabled: enabled
                )
                // A backend without the column ignores the key and answers 200,
                // so compare the echo. `DevicePreferencesResponse` stays tolerant
                // of a missing field for other PATCHes; here missing means failed.
                guard response.bulletinPushEnabled == enabled else {
                    throw PushAPIError.invalidResponse
                }
                await MainActor.run { Defaults[.bulletinPushEnabled] = enabled }
                logger.info("bulletin push enabled=\(enabled, privacy: .public) propagated")
            } catch {
                logger.error("bulletin push enabled=\(enabled, privacy: .public) did not propagate: \(error.localizedDescription, privacy: .private)")
                throw error
            }
        }
        bulletinPatchChain = task
        defer {
            if bulletinPatchChain == task {
                bulletinPatchChain = nil
            }
        }
        try await task.value
    }

    func updateCloudSyncEnabled(_ enabled: Bool) async {
        if isRegistering {
            await withCheckedContinuation { cloudSyncPatchesWaiting.append($0) }
        }
        do {
            _ = try await apiClient.updateDevicePreferences(
                deviceId: identity.uuid,
                cloudSyncEnabled: enabled
            )
            logger.info("[sync] cloud_sync_enabled=\(enabled, privacy: .public) PATCH succeeded")
        } catch {
            logger.error("[sync] cloud_sync_enabled=\(enabled, privacy: .public) PATCH failed: \(error.localizedDescription, privacy: .private)")
        }
        #if os(iOS)
        if enabled, lastError != nil { await registerAgain() }
        #endif
    }

    func updateSyncPreferences() async {
        let predecessor = syncPreferencesPatchChain
        let uuid = identity.uuid
        let apiClient = self.apiClient
        let logger = self.logger
        let task = Task<Void, Never> {
            await predecessor?.value
            let sent = SyncPreferences.current
            Defaults[.syncPreferencesPushPending] = true
            do {
                _ = try await apiClient.updateDevicePreferences(
                    deviceId: uuid,
                    syncCourses: sent.courses,
                    syncCourseColors: sent.courseColors,
                    syncCourseNames: sent.courseNames,
                    syncAssignments: sent.assignments,
                    syncAssignmentReminders: sent.assignmentReminders,
                    syncLiveActivity: sent.liveActivity
                )
                if SyncPreferences.current == sent {
                    Defaults[.syncPreferencesPushPending] = false
                }
            } catch {
                logger.error("[sync] preferences PATCH failed: \(error.localizedDescription, privacy: .private)")
            }
        }
        syncPreferencesPatchChain = task
        defer {
            if syncPreferencesPatchChain == task {
                syncPreferencesPatchChain = nil
            }
        }
        await task.value
    }

    private func resendSyncPreferencesIfPending() async {
        guard Defaults[.syncPreferencesPushPending] else { return }
        logger.info("[sync] re-sending sync preferences a failed PATCH left behind")
        await updateSyncPreferences()
    }

    private nonisolated struct SyncPreferences: Equatable, Sendable {
        let courses: Bool
        let courseColors: Bool
        let courseNames: Bool
        let assignments: Bool
        let assignmentReminders: Bool
        let liveActivity: Bool

        static var current: SyncPreferences {
            SyncPreferences(
                courses: Defaults[.syncCourses],
                courseColors: Defaults[.syncCourseColors],
                courseNames: Defaults[.syncCourseNames],
                assignments: Defaults[.syncAssignments],
                assignmentReminders: Defaults[.syncAssignmentReminders],
                liveActivity: Defaults[.syncLiveActivity]
            )
        }
    }

    func snapshot() -> PushRegistrationSnapshot {
        PushRegistrationSnapshot(
            ptsTokenLength: ptsTokenHex?.count ?? 0,
            deviceTokenLength: deviceTokenHex?.count ?? 0,
            lastError: lastError,
            lastAttemptFoundNoSession: lastAttemptFoundNoSession,
            lastRegisteredAt: lastRegisteredAt
        )
    }

    func awaitPendingRegistration() async {
        while true {
            let attempt = lastAttempt
            let retry = deviceRegisterRetryTask
            await attempt?.value
            await retry?.value
            if lastAttempt == attempt, deviceRegisterRetryTask == retry { return }
        }
    }

    @discardableResult
    func unregister() async -> Bool {
        let landed = await unregisterDevice()
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
        registerAgainIfRunningFails = false
        return landed
    }

    func unregisterDevice(at baseURL: URL? = nil) async -> Bool {
        do {
            try await apiClient.unregisterDevice(deviceId: identity.uuid, at: baseURL)
            logger.info("unregistered device on server")
            return true
        } catch PushAPIError.httpStatus(404, _) {
            logger.info("device already unregistered on server")
            return true
        } catch {
            logger.error("unregister failed: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private var hasRegistrableToken: Bool {
        deviceTokenHex != nil || ptsTokenHex != nil
    }

    private var isRegistering: Bool {
        #if os(macOS)
        registrationsInFlight > 0 || passiveRegistrationsRunning > 0
        #else
        registrationsInFlight > 0
        #endif
    }

    private func releaseCloudSyncPatchesIfIdle() {
        guard !isRegistering else { return }
        let waiting = cloudSyncPatchesWaiting
        cloudSyncPatchesWaiting = []
        for patch in waiting { patch.resume() }
    }

    func registerAgain() async {
        deviceRegisterAttempts = 0
        guard registrationsInFlight == 0 else {
            registerAgainIfRunningFails = true
            return
        }
        deviceRegisterRetryTask?.cancel()
        deviceRegisterRetryTask = nil
        #if os(iOS)
        await registerIfReady()
        #elseif os(macOS)
        await registerPassiveDevice()
        #endif
    }

    func registerAgainIfGaveUp() async {
        guard lastError != nil, registrationGaveUp else { return }
        await registerAgain()
    }

    private var registrationGaveUp: Bool {
        #if os(iOS)
        deviceRegisterAttempts >= maxDeviceRegisterAttempts
        #else
        passiveRegistrationsRunning == 0
        #endif
    }

    private func registerIfReady() async {
        #if os(iOS)
        guard hasRegistrableToken else { return }

        lastAttempt?.cancel()
        let logger = self.logger
        let sleep = debounceSleep
        lastAttempt = Task { [weak self] in
            await sleep(.milliseconds(250))
            if Task.isCancelled { return }
            guard let self else { return }
            await self.performRegister(logger: logger)
        }
        #endif
    }

    private func performRegister(logger: Logger) async {
        var tokens: [PushAPI.PushTokenIn] = []
        if let deviceToken = deviceTokenHex {
            tokens.append(PushAPI.PushTokenIn(
                provider: "apns",
                token_kind: "standard",
                token_value: deviceToken,
                bundle_id: bundleId,
                environment: apnsEnv,
                scope_key: ""
            ))
        }
        if let pts = ptsTokenHex {
            tokens.append(PushAPI.PushTokenIn(
                provider: "apns",
                token_kind: "push_to_start",
                token_value: pts,
                bundle_id: bundleId,
                environment: apnsEnv,
                scope_key: attrsType
            ))
        }
        guard !tokens.isEmpty else { return }
        registrationsInFlight += 1
        defer {
            registrationsInFlight -= 1
            releaseCloudSyncPatchesIfIdle()
        }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        do {
            try await apiClient.registerAnonymousDevice(
                PushAPI.AnonymousDeviceRequest(
                    device_id: identity.uuid,
                    platform: "apple",
                    device_class: deviceClass,
                    push_token: deviceTokenHex,
                    bundle_id: bundleId,
                    server_push_enabled: !Defaults[.serverPushUserOptOut]
                )
            )
        } catch is CancellationError {
        } catch {
            logger.error("device announce failed: \(error.localizedDescription, privacy: .private)")
        }

        do {
            let cloudSync = Defaults[.cloudSyncEnabled]
            logger.info("[register] cloud_sync_enabled=\(cloudSync, privacy: .public)")
            for token in tokens {
                let request = PushAPI.DeviceRegisterRequest(
                    client_device_id: identity.uuid,
                    platform: PushDeviceClass.platform(for: deviceClass),
                    device_class: deviceClass,
                    app_version: appVersion,
                    os_version: { let v = ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }(),
                    device_model: PushDeviceModel.current,
                    locale: Self.currentLocaleTag,
                    push_token: token,
                    cloud_sync_enabled: cloudSync,
                    bulletin_push_enabled: Defaults[.bulletinPushEnabled],
                    server_push_enabled: !Defaults[.serverPushUserOptOut]
                )
                let response = try await apiClient.registerDevice(request)
                logger.info("registered device (\(token.token_kind, privacy: .public)) device_id=\(response.device_id, privacy: .private)")
            }

            deviceRegisterRetryTask?.cancel()
            deviceRegisterRetryTask = nil
            deviceRegisterAttempts = 0
            noteSuccessfulRegistration()
            #if os(iOS)
            await flushPendingActivityRegistrations(logger: logger)
            #endif
            await resendSyncPreferencesIfPending()
        } catch is CancellationError {
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
        } catch {
            logger.error("register failed: \(error.localizedDescription, privacy: .private)")
            noteRegistrationError(error)
            if registerAgainIfRunningFails {
                registerAgainIfRunningFails = false
                await registerIfReady()
            } else {
                scheduleDeviceRegisterRetry(logger: logger)
            }
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
        let sleep = retrySleep
        deviceRegisterRetryTask?.cancel()
        deviceRegisterRetryTask = Task { [weak self] in
            await sleep(.seconds(delay))
            if Task.isCancelled { return }
            await self?.performRegister(logger: logger)
        }
    }

    private func noteSuccessfulRegistration() {
        lastRegisteredAt = Date()
        lastError = nil
        lastAttemptFoundNoSession = false
        registerAgainIfRunningFails = false
    }

    private func noteRegistrationError(_ error: Error) {
        lastError = "register: \(error.localizedDescription)"
        lastAttemptFoundNoSession = if case PushAPIError.notSignedIn = error { true } else { false }
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
        do {
            let response = try await apiClient.registerLiveActivityToken(request)
            logger.info(
                "registered live activity token id=\(response.tokenId, privacy: .private)"
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
                    await registerIfReady()
                    logger.error("live activity token register 404 attempt=\(attempts, privacy: .public) id=\(activityId, privacy: .private) — re-registering device")
                    return
                }
                logger.error("live activity token register 404 exhausted attempts=\(attempts, privacy: .public) id=\(activityId, privacy: .private) — falling back to backoff retry")
            }
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .private)")
            scheduleActivityRegistrationRetry(registration, logger: logger)
        } catch {
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .private)")
            scheduleActivityRegistrationRetry(registration, logger: logger)
        }
    }

    private func scheduleActivityRegistrationRetry(
        _ registration: LiveActivityUpdateTokenRegistration,
        logger: Logger
    ) {
        let activityId = registration.activityId
        let attempt = (activityRegistrationAttempts[activityId] ?? 0) + 1
        activityRegistrationAttempts[activityId] = attempt
        guard attempt < maxActivityRegistrationAttempts else {
            logger.error(
                "giving up on live activity token register attempts=\(attempt, privacy: .public) id=\(activityId, privacy: .private)"
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

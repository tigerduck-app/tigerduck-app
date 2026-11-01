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

/// Debug builds are issued sandbox tokens and TestFlight and App Store builds production ones;
/// the backend picks the APNs host from the value uploaded.
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
    // Internal for `DeviceRegistration` and `ActivityTokenRegistration`, which run isolated to this actor.
    let requests: PushDeviceRequests
    var tokens = HeldTokens()
    var lastAttempt: Task<Void, Never>?
    var status = Status()
    #if os(iOS)
    var activities = ActivityRegistrations()
    #endif
    var retry = DeviceRetry()
    var running = RunningRegistrations()
    let debounceSleep: @Sendable (Duration) async -> Void
    let retrySleep: @Sendable (Duration) async -> Void
    private var chains = PatchChains()

    var logger: Logger { requests.logger }

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
        debounceSleep: @escaping @Sendable (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) },
        retrySleep: @escaping @Sendable (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) }
    ) {
        self.requests = PushDeviceRequests(
            identity: identity, apiClient: apiClient, bundleId: bundleId,
            attrsType: attrsType, apnsEnv: apnsEnv, deviceClass: deviceClass
        )
        self.debounceSleep = debounceSleep
        self.retrySleep = retrySleep
    }

    /// The language the app is rendering, not the device's region setting:
    /// `preferredLocalizations` reflects what actually resolved against the
    /// bundle, so the server's copy matches what the user sees on screen.
    static var currentLocaleTag: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    func update(deviceToken: Data) async {
        let hex = deviceToken.hexEncodedString()
        guard hex != tokens.device else { return }
        tokens.device = hex
        logger.info("device APNs token updated (len=\(hex.count, privacy: .public))")
        registerIfReady()
    }

    func update(ptsTokenHex hex: String) async {
        guard hex != tokens.pts else { return }
        tokens.pts = hex
        logger.info("PTS token updated (len=\(hex.count, privacy: .public))")
        registerIfReady()
    }

    #if os(iOS)
    func registerLiveActivityUpdateToken(
        _ registration: LiveActivityUpdateTokenRegistration
    ) async {
        activities.pending[registration.activityId] = registration
        guard !tokens.isEmpty else {
            registerIfReady()
            return
        }
        await ActivityTokenRegistration.perform(registration, on: self)
    }
    #endif

    #if os(macOS)
    func registerPassiveDevice() async {
        await DeviceRegistration.registerPassive(on: self)
    }
    #endif

    func registrationFailed(_ error: Error) {
        status.lastError = "APNs register failed: \(error.localizedDescription)"
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .private)")
    }

    func uploadHolidayOverride(
        holidayID: Int, notify: Bool, madeAt stamp: Date
    ) async throws -> PushAPI.HolidayOverrideResponse {
        try await requests.apiClient.putHolidayOverride(holidayID: holidayID, notify: notify, madeAt: stamp)
    }

    func updateServerPushOptOut(_ optOut: Bool) async throws {
        let requests = self.requests, predecessor = chains.optOut, tokenHex = tokens.device
        let task = Task<Void, Error> {
            try await requests.sendServerPushOptOut(optOut, deviceToken: tokenHex, after: predecessor)
        }
        chains.optOut = task
        defer {
            if chains.optOut == task { chains.optOut = nil }
        }
        try await task.value
    }

    func updateBulletinPushEnabled(_ enabled: Bool) async throws {
        let requests = self.requests, predecessor = chains.bulletin
        let task = Task<Void, Error> { try await requests.sendBulletinPushEnabled(enabled, after: predecessor) }
        chains.bulletin = task
        defer {
            if chains.bulletin == task { chains.bulletin = nil }
        }
        try await task.value
    }

    func updateCloudSyncEnabled(_ enabled: Bool) async {
        if running.isRegistering {
            await withCheckedContinuation { running.cloudSyncPatchesWaiting.append($0) }
        }
        await requests.sendCloudSyncEnabled(enabled)
        #if os(iOS)
        if enabled, status.lastError != nil { await registerAgain() }
        #endif
    }

    func updateSyncPreferences() async {
        let requests = self.requests, predecessor = chains.syncPreferences
        let task = Task<Void, Never> { await requests.sendSyncPreferences(after: predecessor) }
        chains.syncPreferences = task
        defer {
            if chains.syncPreferences == task { chains.syncPreferences = nil }
        }
        await task.value
    }

    func resendSyncPreferencesIfPending() async {
        guard Defaults[.syncPreferencesPushPending] else { return }
        logger.info("[sync] re-sending sync preferences a failed PATCH left behind")
        await updateSyncPreferences()
    }

    func snapshot() -> PushRegistrationSnapshot {
        PushRegistrationSnapshot(
            ptsTokenLength: tokens.pts?.count ?? 0,
            deviceTokenLength: tokens.device?.count ?? 0,
            lastError: status.lastError,
            lastAttemptFoundNoSession: status.foundNoSession,
            lastRegisteredAt: status.registeredAt
        )
    }

    func awaitPendingRegistration() async {
        while true {
            let attempt = lastAttempt
            let retryTask = retry.task
            await attempt?.value
            await retryTask?.value
            if lastAttempt == attempt, retry.task == retryTask { return }
        }
    }

    @discardableResult
    func unregister() async -> Bool {
        let landed = await unregisterDevice()
        tokens = HeldTokens()
        #if os(iOS)
        activities.removeAll()
        #endif
        retry.cancel()
        retry.attempts = 0
        retry.againIfRunningFails = false
        return landed
    }

    func unregisterDevice(at baseURL: URL? = nil) async -> Bool {
        await requests.unregister(at: baseURL)
    }

    func registerAgain() async {
        retry.attempts = 0
        guard running.inFlight == 0 else {
            retry.againIfRunningFails = true
            return
        }
        retry.cancel()
        #if os(iOS)
        registerIfReady()
        #elseif os(macOS)
        await registerPassiveDevice()
        #endif
    }

    func registerAgainIfGaveUp() async {
        guard status.lastError != nil, registrationGaveUp else { return }
        await registerAgain()
    }

    private var registrationGaveUp: Bool {
        #if os(iOS)
        retry.attempts >= DeviceRetry.maxAttempts
        #else
        running.passive == 0
        #endif
    }

    func registerIfReady() {
        DeviceRegistration.registerIfReady(on: self)
    }
}

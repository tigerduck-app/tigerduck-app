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

/// `device_class` value the iOS client reports. Drives operator-side
/// targeting (iPhone vs iPad vs Mac) without needing the backend to
/// re-parse build metadata.
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
    /// The same, for the bulletin page's toggle. A chain of its own rather
    /// than a shared one: the two PATCH different columns and neither has
    /// to wait on the other, but two taps on *this* toggle inside one round
    /// trip must still land in the order they were made.
    private var bulletinPatchChain: Task<Void, Error>?
    /// The same, for the "Synced content" switches.
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

    // Same retry shape for device registration: a transient 5xx leaving the
    // device permanently un-pushable was the original bug.
    private var deviceRegisterRetryTask: Task<Void, Never>?
    private var deviceRegisterAttempts: Int = 0
    private let maxDeviceRegisterAttempts = 4

    /// The registration debounce's wait, injectable so a test need not sleep through it. The
    /// retry backoffs keep their own sleeps.
    private let debounceSleep: @Sendable (Duration) async -> Void

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
        debounceSleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.identity = identity
        self.apiClient = apiClient
        self.bundleId = bundleId
        self.attrsType = attrsType
        self.apnsEnv = apnsEnv
        self.deviceClass = deviceClass
        self.debounceSleep = debounceSleep
    }

    // MARK: - Locale

    /// The language the app is rendering, not the device's region setting:
    /// `preferredLocalizations` reflects what actually resolved against the
    /// bundle, so the server's copy matches what the user sees on screen.
    static var currentLocaleTag: String {
        Bundle.main.preferredLocalizations.first ?? "en"
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
        // Parked until the device itself can register; the success path in
        // `performRegister` flushes it.
        guard hasRegistrableToken else {
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
            logger.info("registered passive macOS device device_id=\(response.device_id, privacy: .public)")
            noteSuccessfulRegistration()
            await resendSyncPreferencesIfPending()
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

    /// PUT one holiday exception so the user's other devices agree.
    func uploadHolidayOverride(holidayID: Int, notify: Bool) async throws {
        try await apiClient.putHolidayOverride(holidayID: holidayID, notify: notify)
    }

    /// Called from the settings toggle. Updates the server first and flips
    /// the local pref only after a 2xx, so a transient failure cannot leave
    /// local state claiming the server agrees. Throws so the caller can roll
    /// back the toggle and show the error. The next `/devices/register` also
    /// re-sends the value, so a later success restores consistency.
    ///
    /// Calls run in tap order on `optOutPatchChain`, with no cancellation
    /// check: a cancel after the server accepted would desync `Defaults`.
    func updateServerPushOptOut(_ optOut: Bool) async throws {
        let predecessor = optOutPatchChain
        let uuid = identity.uuid
        let apiClient = self.apiClient
        let logger = self.logger
        let deviceClass = self.deviceClass
        let bundleId = self.bundleId
        let tokenHex = self.deviceTokenHex
        let task = Task<Void, Error> {
            // Tolerate predecessor failure — each tap's success is
            // independent of whether the previous one succeeded; we just
            // need its work to be done before ours starts.
            _ = try? await predecessor?.value
            do {
                // Operator targeting reads `user_devices` while signed in and
                // `device_registrations` while not. Announce regardless, for a
                // later sign-out; PATCH only with a session, or it is a sure 401.
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
                logger.error("server push opt-out did not propagate: \(error.localizedDescription, privacy: .public)")
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

    /// Called from the bulletin page's toggle. PATCHes the server first and
    /// flips the local pref only after a 2xx, so local state never claims a
    /// change the server lacks; throws so the page keeps its pre-tap state.
    /// The next `/devices/register` (`performRegister`) also re-sends it.
    /// Unlike `updateServerPushOptOut` there is no signed-out row to announce
    /// to: only `user_devices` holds this flag, and the page needs a session.
    /// Calls run in tap order on `bulletinPatchChain`, so the server keeps the
    /// last tap rather than whichever racing PATCH landed last.
    func updateBulletinPushEnabled(_ enabled: Bool) async throws {
        let predecessor = bulletinPatchChain
        let uuid = identity.uuid
        let apiClient = self.apiClient
        let logger = self.logger
        let task = Task<Void, Error> {
            // Tolerate predecessor failure — each tap's success is
            // independent of whether the previous one succeeded; we just
            // need its work to be done before ours starts.
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
                logger.error("bulletin push enabled=\(enabled, privacy: .public) did not propagate: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }
        bulletinPatchChain = task
        defer {
            // Don't pin a long-completed task as the chain head — clear
            // it unless a newer call has already taken our place.
            if bulletinPatchChain == task {
                bulletinPatchChain = nil
            }
        }
        try await task.value
    }

    func updateCloudSyncEnabled(_ enabled: Bool) async {
        do {
            _ = try await apiClient.updateDevicePreferences(
                deviceId: identity.uuid,
                cloudSyncEnabled: enabled
            )
            logger.info("[sync] cloud_sync_enabled=\(enabled, privacy: .public) PATCH succeeded")
        } catch {
            logger.error("[sync] cloud_sync_enabled=\(enabled, privacy: .public) PATCH failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// PATCHes the six "Synced content" switches as they stand when the
    /// request goes out. They persist on flip and registration omits them,
    /// so a failed PATCH would leave the server on old values until the next
    /// flip. `syncPreferencesPushPending` is set before every PATCH, cleared
    /// only when one lands with the switches unchanged, and while it is set
    /// each successful registration is followed by another PATCH.
    /// Calls queue on `syncPreferencesPatchChain` and read the switches on
    /// their turn, so the last PATCH to land carries the latest values.
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
                logger.error("[sync] preferences PATCH failed: \(error.localizedDescription, privacy: .public)")
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

    /// Sends the sync switches again if a PATCH of them never landed. Run
    /// once the server has accepted a registration, the sign that it can
    /// be reached again.
    private func resendSyncPreferencesIfPending() async {
        guard Defaults[.syncPreferencesPushPending] else { return }
        logger.info("[sync] re-sending sync preferences a failed PATCH left behind")
        await updateSyncPreferences()
    }

    /// The six switches as one value, so a PATCH can tell whether what it
    /// sent is still what they say.
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

    /// Snapshot of internal state for UI display. Safe to call from any isolation.
    func snapshot() -> PushRegistrationSnapshot {
        PushRegistrationSnapshot(
            ptsTokenLength: ptsTokenHex?.count ?? 0,
            deviceTokenLength: deviceTokenHex?.count ?? 0,
            lastError: lastError,
            lastRegisteredAt: lastRegisteredAt
        )
    }

    /// Waits for the debounced registration attempt, if one is scheduled,
    /// to finish. The debounce runs in an unstructured `Task`, so this is
    /// the only way for a caller to observe the attempt's outcome
    /// deterministically.
    func awaitPendingRegistration() async {
        await lastAttempt?.value
    }

    // MARK: - Unregister

    /// Called on sign-out, and only there. Its one caller is
    /// `PushCoordinator.disable()`, whose one caller is `AppState.logout()`
    /// — there is no longer a switch that takes the push stack down, only
    /// the per-channel opt-outs, which leave the device registered.
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

    /// Whether the device holds a token `performRegister` can register.
    /// Either one will do; see `registerIfReady`.
    private var hasRegistrableToken: Bool {
        deviceTokenHex != nil || ptsTokenHex != nil
    }

    /// Re-attempt registration after the auth state changes — the user just
    /// signed in and a v3 JWT is now available. Resets the give-up counter so
    /// a registration that exhausted its retries while unauthenticated gets a
    /// fresh chance, then fires immediately (subject to `registerIfReady`'s
    /// token gate).
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

    /// Registers as soon as the device holds either token. The APNs token must
    /// not wait for the push-to-start one, which exists only while Live
    /// Activities are on: assignment reminders go to the APNs token, and
    /// registering tells the server the app version, locale and cloud-sync flag.
    /// A later token gets a fresh attempt that re-sends every token held.
    /// Both arrive within tens of ms at launch, so a 250 ms debounce merges
    /// them into one attempt; the superseded one's `CancellationError` is
    /// expected and silenced. iOS only; the Mac uses `registerPassiveDevice`.
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

    /// Re-reads the current tokens inside the actor and POSTs one
    /// registration per token held: `/devices/register` carries a single
    /// `push_token`, so the standard and PTS tokens travel separately, and
    /// every attempt re-sends both (the server upserts). Split out so the
    /// debounce `Task` can call an actor-isolated method for fresh state
    /// instead of capturing stale `let`s from the enqueue site.
    private func performRegister(logger: Logger) async {
        var tokens: [PushAPI.PushTokenIn] = []
        // The standard token first: it is the one reminders are sent to.
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
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

        // Announce every launch, signed in or not: signed out, operator push
        // reads only `device_registrations`. Best effort: an error here must
        // not fail the registration. See docs/decisions/0008-device-announce.md.
        do {
            try await apiClient.registerAnonymousDevice(
                PushAPI.AnonymousDeviceRequest(
                    device_id: identity.uuid,
                    platform: "apple",
                    device_class: deviceClass,
                    push_token: deviceTokenHex,
                    bundle_id: bundleId,
                    // Sent on every announce, not only on change: signed out,
                    // targeting filters on this row and the PATCH has no session,
                    // so the announce is the opt-out's only path to the server.
                    server_push_enabled: !Defaults[.serverPushUserOptOut]
                )
            )
        } catch is CancellationError {
        } catch {
            logger.error("device announce failed: \(error.localizedDescription, privacy: .public)")
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
                logger.info("registered device (\(token.token_kind, privacy: .public)) device_id=\(response.device_id, privacy: .public)")
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
        // Identity comes from the JWT. `countdown_target` becomes the end job's
        // `fire_at` on the server's real clock, so it is sent in real time and
        // snapshot dates in app time. See docs/decisions/0006-debug-clock.md.
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
        // If a newer registration replaced this activity's pending entry (for
        // example after Apple rotated the update token), its own success and
        // retry cycle owns it from here, so drop this retry.
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

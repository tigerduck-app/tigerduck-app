import Foundation
import UIKit
import WatchConnectivity
import Combine
import os

protocol WatchSessionPushing: AnyObject {
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isReachable: Bool { get }
    func updateApplicationContext(_ context: [String: Any]) throws
    @discardableResult
    func transferUserInfo(_ userInfo: [String: Any]) -> WCSessionUserInfoTransfer
    func sendMessage(_ message: [String: Any],
                     replyHandler: (([String: Any]) -> Void)?,
                     errorHandler: ((Error) -> Void)?)
}

extension WCSession: WatchSessionPushing {}

@MainActor
final class WatchSyncCoordinator: NSObject {

    struct Payload {
        let courses: [SDCourse]
        let customNames: [String: String]
        let accentHex: String
        let loggedIn: Bool
        let languageTag: String?
        let visualPreset: VisualPreset
        var quietDays: Set<String> = []
        var changes: CourseChanges = .empty
    }

    private let session: WatchSessionPushing
    private(set) var debounceTask: Task<Void, Never>?
    private var pendingPayload: Payload?
    private var pendingForce = false
    private var pendingSnapshot: WatchSnapshot?
    private var lastDelivered: WatchSnapshot?
    private var payloadSource: (@MainActor () -> Payload)?
    private var isActivated = false
    private let debounceInterval: Duration = .milliseconds(500)
    private let sleep: @Sendable (Duration) async -> Void
    private let republishCredentials: @MainActor () -> Void
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private var owesCredentials = false
    private var owesStatePush = false
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(
        session: WatchSessionPushing = WCSession.default,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0, clock: .suspending) },
        republishCredentials: (@MainActor () -> Void)? = nil,
        isProtectedDataAvailable: (@MainActor () -> Bool)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.session = session
        self.sleep = sleep
        self.republishCredentials = republishCredentials ?? {
            WatchLibraryCredentialBroadcaster.shared.republishIfCredentialed()
            TLSPinWatchBroadcaster.shared.broadcast()
        }
        self.isProtectedDataAvailable = isProtectedDataAvailable
            ?? { UIApplication.shared.isProtectedDataAvailable }
        self.notificationCenter = notificationCenter
        super.init()
        observers = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ].map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendOwed() }
            }
        }
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    func activate() {
        guard !isActivated, let wcSession = session as? WCSession else { return }
        isActivated = true
        wcSession.delegate = self
        wcSession.activate()
    }

    func setPayloadSource(_ source: @escaping @MainActor () -> Payload) {
        payloadSource = source
    }

    func pushCurrentState(force: Bool = false) {
        guard let payloadSource else { return }
        guard isProtectedDataAvailable() else {
            owesStatePush = true
            return
        }
        scheduleDebouncedPush(payloadSource(), force: force)
    }

    func answerSyncRequest() {
        pushCurrentState(force: true)
        owesCredentials = true
        sendOwed()
    }

    private func sendOwed() {
        guard isProtectedDataAvailable() else { return }
        if owesStatePush {
            owesStatePush = false
            pushCurrentState(force: true)
        }
        if owesCredentials {
            owesCredentials = false
            republishCredentials()
        }
    }

    func push(
        courses: [SDCourse],
        customNames: [String: String],
        accentHex: String,
        loggedIn: Bool,
        languageTag: String?,
        visualPreset: VisualPreset,
        quietDays: Set<String> = [],
        changes: CourseChanges = .empty,
        force: Bool = false
    ) {
        let snapshot = { (syncedAt: Date) in
            WatchPayloadEncoder.encode(
                courses: courses, customNames: customNames, accentHex: accentHex,
                syncedAt: syncedAt, loggedIn: loggedIn, languageTag: languageTag,
                visualPreset: visualPreset, quietDays: quietDays, changes: changes
            )
        }
        if !force, pendingSnapshot == nil, let last = lastDelivered, snapshot(last.syncedAt) == last {
            return
        }
        deliver(snapshot(Date()))
    }

    /// Attempt to deliver `snapshot` to the watch. If the watch isn't reachable
    /// yet (session not activated, no paired watch, or app not installed), the
    /// snapshot is held in `pendingSnapshot` and flushed by the next activation
    /// completion or `sessionWatchStateDidChange` callback. Delivery errors
    /// also keep the snapshot pending so a later state change can retry.
    private func deliver(_ snapshot: WatchSnapshot) {
        guard session.isPaired, session.isWatchAppInstalled else {
            pendingSnapshot = snapshot
            return
        }
        do {
            let dict = try WatchPayloadCodec.encode(snapshot)
            try session.updateApplicationContext(dict)
            pendingSnapshot = nil
            lastDelivered = snapshot
        } catch {
            AppLogger.network.error("watch context push failed: \(error.localizedDescription)")
            pendingSnapshot = snapshot
        }
    }

    private func flushPendingIfReady() {
        guard let snapshot = pendingSnapshot else { return }
        deliver(snapshot)
    }

    func scheduleDebouncedPush(_ payload: Payload, force: Bool = false) {
        pendingPayload = payload
        pendingForce = pendingForce || force
        debounceTask?.cancel()
        let sleep = self.sleep
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            await sleep(interval)
            guard !Task.isCancelled, let self, let p = self.pendingPayload else { return }
            let force = self.pendingForce
            self.pendingPayload = nil
            self.pendingForce = false
            self.push(courses: p.courses, customNames: p.customNames, accentHex: p.accentHex,
                      loggedIn: p.loggedIn, languageTag: p.languageTag,
                      visualPreset: p.visualPreset, quietDays: p.quietDays, changes: p.changes, force: force)
        }
    }
}

extension WatchSyncCoordinator: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        if let error {
            AppLogger.network.error("phone WC activation: \(error.localizedDescription)")
        }
        if state == .activated {
            Task { @MainActor in self.flushPendingIfReady() }
        }
    }

    // iOS-only delegate methods required by the protocol
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.flushPendingIfReady() }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        guard let kind = message[WatchWireFormat.MessageKey.kind] as? String,
              kind == WatchWireFormat.MessageKind.syncRequest else { return }
        Task { @MainActor in self.answerSyncRequest() }
    }

    /// Reply-expecting messages. The watch asks for a library QR here so it
    /// can show one without internet of its own while the phone is in
    /// Bluetooth range. Answered from `LibraryQRCache` while that code has
    /// `reuseThreshold` seconds left (both screens then show the same
    /// code), otherwise fetched with the phone's own library token. Needs
    /// the phone unlocked for the Keychain read; a locked phone replies
    /// with an error and the watch falls back to its own radio.
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[WatchWireFormat.MessageKey.kind] as? String
                == WatchWireFormat.MessageKind.libraryQRRequest else {
            self.session(session, didReceiveMessage: message)
            replyHandler([:])
            return
        }
        Task { @MainActor in replyHandler(await Self.libraryQRReply()) }
    }

    static func libraryQRReply(
        cache: LibraryQRCache = .shared,
        generation: @MainActor () -> Int = { LibraryService.loginGeneration },
        generate: () async throws -> String = { try await LibraryService.generateQRCode() }
    ) async -> [String: Any] {
        if let payload = cache.reusable() {
            return [
                WatchWireFormat.LibraryQRKey.payload: payload,
                WatchWireFormat.LibraryQRKey.remaining: cache.remaining(),
            ]
        }
        let started = generation()
        do {
            let payload = try await generate()
            guard generation() == started else {
                return [WatchWireFormat.LibraryQRKey.error: LibraryServiceError.credentialsNotFound.localizedDescription]
            }
            cache.store(payload)
            return [
                WatchWireFormat.LibraryQRKey.payload: payload,
                WatchWireFormat.LibraryQRKey.remaining: LibraryQRCache.lifetime,
            ]
        } catch {
            return [WatchWireFormat.LibraryQRKey.error: error.localizedDescription]
        }
    }
}

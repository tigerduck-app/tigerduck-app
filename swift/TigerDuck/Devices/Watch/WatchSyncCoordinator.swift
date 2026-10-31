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

    /// The push waiting out its debounce, and the snapshot still owed to the watch.
    private struct Pending {
        var payload: Payload?
        var force = false
        var snapshot: WatchSnapshot?
        var lastDelivered: WatchSnapshot?
    }

    /// What waits for protected data to come back after a locked-device attempt.
    private struct Owed {
        var credentials = false
        var statePush = false
    }

    private struct Dependencies {
        let sleep: @Sendable (Duration) async -> Void
        let republishCredentials: @MainActor () -> Void
        let isProtectedDataAvailable: @MainActor () -> Bool
    }

    private let session: WatchSessionPushing
    private(set) var debounceTask: Task<Void, Never>?
    private var pending = Pending()
    private var payloadSource: (@MainActor () -> Payload)?
    private var isActivated = false
    private let debounceInterval: Duration = .milliseconds(500)
    private let deps: Dependencies
    private var owed = Owed()
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
        deps = Dependencies(
            sleep: sleep,
            republishCredentials: republishCredentials ?? {
                WatchLibraryCredentialBroadcaster.shared.republishIfCredentialed()
                TLSPinWatchBroadcaster.shared.broadcast()
            },
            isProtectedDataAvailable: isProtectedDataAvailable ?? { UIApplication.shared.isProtectedDataAvailable }
        )
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
        guard deps.isProtectedDataAvailable() else {
            owed.statePush = true
            return
        }
        scheduleDebouncedPush(payloadSource(), force: force)
    }

    func answerSyncRequest() {
        pushCurrentState(force: true)
        owed.credentials = true
        sendOwed()
    }

    private func sendOwed() {
        guard deps.isProtectedDataAvailable() else { return }
        if owed.statePush {
            owed.statePush = false
            pushCurrentState(force: true)
        }
        if owed.credentials {
            owed.credentials = false
            deps.republishCredentials()
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
        if !force, pending.snapshot == nil, let last = pending.lastDelivered, snapshot(last.syncedAt) == last {
            return
        }
        deliver(snapshot(Date()))
    }

    /// Attempt to deliver `snapshot` to the watch. If the watch isn't reachable
    /// yet (session not activated, no paired watch, or app not installed), the
    /// snapshot is held in `pending.snapshot` and flushed by the next activation
    /// completion or `sessionWatchStateDidChange` callback. Delivery errors
    /// also keep the snapshot pending so a later state change can retry.
    private func deliver(_ snapshot: WatchSnapshot) {
        guard session.isPaired, session.isWatchAppInstalled else {
            pending.snapshot = snapshot
            return
        }
        do {
            let dict = try WatchPayloadCodec.encode(snapshot)
            try session.updateApplicationContext(dict)
            pending.snapshot = nil
            pending.lastDelivered = snapshot
        } catch {
            AppLogger.network.error("watch context push failed: \(error.localizedDescription)")
            pending.snapshot = snapshot
        }
    }

    private func flushPendingIfReady() {
        guard let snapshot = pending.snapshot else { return }
        deliver(snapshot)
    }

    func scheduleDebouncedPush(_ payload: Payload, force: Bool = false) {
        pending.payload = payload
        pending.force = pending.force || force
        debounceTask?.cancel()
        let sleep = deps.sleep
        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            await sleep(interval)
            guard !Task.isCancelled, let self, let p = self.pending.payload else { return }
            let force = self.pending.force
            self.pending.payload = nil
            self.pending.force = false
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
        account: AccountSession = .library,
        generate: () async throws -> String = { try await LibraryService.generateQRCode() }
    ) async -> [String: Any] {
        if let payload = cache.reusable() {
            return [
                WatchWireFormat.LibraryQRKey.payload: payload,
                WatchWireFormat.LibraryQRKey.remaining: cache.remaining(),
            ]
        }
        let ticket = account.ticket
        do {
            let payload = try await generate()
            guard account.isCurrent(ticket) else {
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

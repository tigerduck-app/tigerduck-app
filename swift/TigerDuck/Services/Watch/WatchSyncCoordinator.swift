import Foundation
import WatchConnectivity
import Combine
import os

/// Narrow protocol over WCSession so we can stub it in tests.
protocol WatchSessionPushing: AnyObject {
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    func updateApplicationContext(_ context: [String: Any]) throws
}

extension WCSession: WatchSessionPushing {}

@MainActor
final class WatchSyncCoordinator: NSObject {

    private let session: WatchSessionPushing
    private var debounceTask: Task<Void, Never>?
    private var pendingPayload: PendingPayload?
    private let debounceInterval: TimeInterval = 0.5

    private struct PendingPayload {
        let courses: [SDCourse]
        let customNames: [String: String]
        let accentHex: String
        let loggedIn: Bool
        let languageTag: String?
    }

    init(session: WatchSessionPushing = WCSession.default) {
        self.session = session
        super.init()
    }

    func activate() {
        guard let wcSession = session as? WCSession else { return }
        wcSession.delegate = self
        wcSession.activate()
    }

    /// Push immediately (used in tests). Production code uses
    /// `scheduleDebouncedPush(...)` to coalesce bursts.
    func push(
        courses: [SDCourse],
        customNames: [String: String],
        accentHex: String,
        loggedIn: Bool,
        languageTag: String?
    ) {
        guard session.isPaired, session.isWatchAppInstalled else { return }
        let snapshot = WatchPayloadEncoder.encode(
            courses: courses, customNames: customNames, accentHex: accentHex,
            syncedAt: Date(), loggedIn: loggedIn, languageTag: languageTag
        )
        do {
            let dict = try WatchPayloadCodec.encode(snapshot)
            try session.updateApplicationContext(dict)
        } catch {
            AppLogger.network.error("watch context push failed: \(error.localizedDescription)")
        }
    }

    func scheduleDebouncedPush(
        courses: [SDCourse],
        customNames: [String: String],
        accentHex: String,
        loggedIn: Bool,
        languageTag: String?
    ) {
        pendingPayload = PendingPayload(
            courses: courses, customNames: customNames,
            accentHex: accentHex, loggedIn: loggedIn, languageTag: languageTag
        )
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.debounceInterval ?? 0.5) * 1_000_000_000))
            guard !Task.isCancelled, let self, let p = self.pendingPayload else { return }
            self.pendingPayload = nil
            self.push(courses: p.courses, customNames: p.customNames, accentHex: p.accentHex,
                      loggedIn: p.loggedIn, languageTag: p.languageTag)
        }
    }
}

// MARK: - WCSessionDelegate (production only; ignored when session is a stub)

extension WatchSyncCoordinator: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        if let error {
            AppLogger.network.error("phone WC activation: \(error.localizedDescription)")
        }
    }

    // iOS-only delegate methods required by the protocol
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {}

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        guard let kind = message[WatchWireFormat.MessageKey.kind] as? String,
              kind == WatchWireFormat.MessageKind.syncRequest else { return }
        Task { @MainActor in
            // Subscribers in Task 17 will hook into this to re-emit current state.
            NotificationCenter.default.post(name: .watchSyncRequested, object: nil)
        }
    }
}

extension Notification.Name {
    static let watchSyncRequested = Notification.Name("watchSyncRequested")
}

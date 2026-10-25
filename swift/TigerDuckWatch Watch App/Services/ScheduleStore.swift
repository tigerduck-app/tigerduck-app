import Foundation
import WatchConnectivity
import WidgetKit
import Combine
import os

@MainActor
final class ScheduleStore: NSObject, ObservableObject {

    @Published private(set) var snapshot: WatchSnapshot?

    var language: WatchLanguage { WatchLanguage(tag: snapshot?.languageTag) }

    private let snapshotFileURL: URL
    private let defaults: UserDefaults
    private let widgetReloader: () -> Void
    private let cooldown: TimeInterval = 600

    private enum DefaultsKey {
        static let lastSyncRequestEpoch = "lastSyncRequestEpoch"
    }

    init(
        snapshotFileURL: URL = SharedAppGroup.snapshotFileURL,
        defaults: UserDefaults = SharedAppGroup.defaults,
        widgetReloader: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() }
    ) {
        self.snapshotFileURL = snapshotFileURL
        self.defaults = defaults
        self.widgetReloader = widgetReloader
        super.init()
        let cached = loadFromDisk()
        self.snapshot = cached
        if let cached { applyClockOverride(from: cached) }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func persist(_ snapshot: WatchSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotFileURL, options: .atomic)
        self.snapshot = snapshot
        applyClockOverride(from: snapshot)
        widgetReloader()
    }

    private func applyClockOverride(from snapshot: WatchSnapshot) {
        AppClock.setOverride(ClockOverride.decode(snapshotJSON: snapshot.clockOverrideJSON))
    }

    private func loadFromDisk() -> WatchSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: snapshotFileURL)
            return try JSONDecoder().decode(WatchSnapshot.self, from: data)
        } catch {
            WatchAppLogger.wc.error("loadFromDisk decode failed: \(error.localizedDescription)")
            return nil
        }
    }

    func shouldRequestSync(at date: Date = Date()) -> Bool {
        let last = defaults.double(forKey: DefaultsKey.lastSyncRequestEpoch)
        if last == 0 { return true }
        return date.timeIntervalSince1970 - last >= cooldown
    }

    func recordSyncRequest(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: DefaultsKey.lastSyncRequestEpoch)
    }

    func clearSyncRequestRecord() {
        defaults.removeObject(forKey: DefaultsKey.lastSyncRequestEpoch)
    }

    func requestSync(force: Bool = false) {
        let now = Date()
        guard force || shouldRequestSync(at: now) else { return }
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        recordSyncRequest(at: now)
        WCSession.default.sendMessage(
            [WatchWireFormat.MessageKey.kind: WatchWireFormat.MessageKind.syncRequest],
            replyHandler: nil,
            errorHandler: { [weak self] error in
                WatchAppLogger.wc.error("sync request failed: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.clearSyncRequestRecord()
                }
            }
        )
    }
}

extension ScheduleStore: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        if let error {
            WatchAppLogger.wc.error("activation error: \(error.localizedDescription)")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            if !WatchLibraryCredentialsStore.shared.hasCredentials { self.requestSync() }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            do {
                let snapshot = try WatchPayloadCodec.decode(applicationContext)
                try self.persist(snapshot)
            } catch {
                WatchAppLogger.wc.error("decode failed: \(error.localizedDescription) — keeping prior cache")
            }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any]) {
        Self.route(userInfo, source: "userInfo")
    }

    /// broadcaster prefers `sendMessage` when reachable because
    /// `transferUserInfo` is unreliable on paired simulators.
    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any]) {
        Self.route(message, source: "message")
    }

    nonisolated static func route(
        _ dict: [String: Any],
        source: String,
        pinEngine: TLSPinEngine = .shared,
        pinDefaults: UserDefaults = .standard
    ) {
        let kind = dict[WatchWireFormat.LibraryCredentialKey.kind] as? String
        guard let json = dict[WatchWireFormat.LibraryCredentialKey.payload] as? String else {
            WatchAppLogger.wc.notice("ignoring \(source, privacy: .public) with no payload")
            return
        }
        switch kind {
        case WatchWireFormat.UserInfoKind.libraryCredential:
            routeCredential(json, source: source)
        case WatchWireFormat.UserInfoKind.tlsPins:
            let applied = WatchTLSPinPayload.apply(json: json, to: pinEngine, defaults: pinDefaults)
            WatchAppLogger.wc.notice("TLS pin payload from=\(source, privacy: .public) applied=\(applied, privacy: .public)")
        default:
            WatchAppLogger.wc.notice("ignoring \(source, privacy: .public) with unknown kind")
        }
    }

    nonisolated private static func routeCredential(_ json: String, source: String) {
        Task { @MainActor in
            do {
                let payload = try WatchLibraryCredentialPayload.decode(json: json)
                let result = WatchLibraryCredentialsStore.shared.apply(payload)
                WatchAppLogger.wc.notice("credential payload from=\(source, privacy: .public) epoch=\(payload.credEpoch) kind=\(payload.kind.rawValue, privacy: .public) result=\(String(describing: result), privacy: .public)")
            } catch {
                WatchAppLogger.wc.error("credential payload decode failed: \(error.localizedDescription)")
            }
        }
    }
}

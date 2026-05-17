import Foundation
import WatchConnectivity
import WidgetKit
import Combine
import os

@MainActor
final class ScheduleStore: NSObject, ObservableObject {

    @Published private(set) var snapshot: WatchSnapshot?

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
        // Re-apply any cached override from the last push so the watch
        // wakes up still pinned to the same fake time the phone is on.
        if let cached { applyClockOverride(from: cached) }
    }

    // MARK: - WC activation

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Persistence (unit-tested)

    func persist(_ snapshot: WatchSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: snapshotFileURL, options: .atomic)
        self.snapshot = snapshot
        applyClockOverride(from: snapshot)
        widgetReloader()
    }

    /// Mirrors the phone's debug time override into the watch's `AppClock`
    /// so `NowNextView`/`TodayView` see the same fake "now". When the
    /// phone clears the override the snapshot carries `nil`, which clears
    /// the watch side too — keeps the two in lockstep. Watch-side
    /// persistence isn't needed: on next launch the watch starts at real
    /// time and the first incoming snapshot re-applies the override.
    private func applyClockOverride(from snapshot: WatchSnapshot) {
        guard let json = snapshot.clockOverrideJSON,
              let data = json.data(using: .utf8),
              let override = try? JSONDecoder().decode(ClockOverride.self, from: data) else {
            AppClock.setOverride(nil)
            return
        }
        AppClock.setOverride(override)
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

    // MARK: - Sync request (unit-tested)

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
        // Arm the cooldown optimistically so simultaneous calls don't pile
        // up sendMessages; roll it back in the error handler so a transient
        // WC failure doesn't strand the watch with stale data for 10 min.
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

// MARK: - WCSessionDelegate

extension ScheduleStore: WCSessionDelegate {

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        if let error {
            WatchAppLogger.wc.error("activation error: \(error.localizedDescription)")
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
}

import Foundation
import os
import TigerDuckCore

nonisolated final class WidgetSnapshotStore {
    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Widget")

    /// `UserDefaults(suiteName:)` cannot tell. It returns nil only for reserved names (this
    /// process's bundle identifier, `NSGlobalDomain`); for a group without the entitlement it
    /// returns a process-local store, so app writes never reach the extension, the failure the
    /// `init` assertion catches. The container URL is nil unless the running binary has the
    /// entitlement. Static and non-private so `AppGroupEntitlementTests` can check it without
    static func isAppGroupAvailable(_ identifier: String) -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) != nil
    }

    init(appGroupIdentifier: String = WidgetSnapshot.appGroupIdentifier) {
        let requiresSharedContainer = appGroupIdentifier == WidgetSnapshot.appGroupIdentifier
        if !requiresSharedContainer || Self.isAppGroupAvailable(appGroupIdentifier),
           let suite = UserDefaults(suiteName: appGroupIdentifier) {
            self.defaults = suite
        } else {
            assertionFailure(
                "App Group suite '\(appGroupIdentifier)' unavailable — verify `com.apple.security.application-groups` is populated in BOTH the TigerDuck app AND TigerDuckWidgets extension entitlements and that the App Group capability is enabled on each target."
            )
            self.defaults = .standard
            logger.error("App Group suite '\(appGroupIdentifier, privacy: .public)' unavailable — widget will not see app-side snapshots")
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        self.decoder = dec
    }

    func readSnapshot() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: WidgetSnapshot.storeKey) else { return nil }
        do {
            let snapshot = try decoder.decode(WidgetSnapshot.self, from: data)
            guard snapshot.version == WidgetSnapshot.currentVersion else {
                logger.notice("widget snapshot version \(snapshot.version) does not match expected \(WidgetSnapshot.currentVersion); treating as missing")
                return nil
            }
            return snapshot
        } catch {
            logger.error("widget snapshot decode failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func readSnapshot(of personID: String?) -> WidgetSnapshot? {
        guard let personID, let person = readPeople().first(where: { $0.id == personID }) else { return readSnapshot() }
        return person.snapshot
    }

    func readPeople() -> [WidgetPersonSnapshot] {
        guard let data = defaults.data(forKey: WidgetSnapshot.peopleStoreKey) else { return [] }
        do {
            let stored = try decoder.decode([Lenient<WidgetPersonSnapshot>].self, from: data)
            let people = stored.compactMap(\.value)
            if people.count != stored.count {
                logger.warning("widget people: dropped \(stored.count - people.count, privacy: .public) undecodable entries")
            }
            return people.filter { $0.snapshot.version == WidgetSnapshot.currentVersion }
        } catch {
            logger.error("widget people decode failed: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    func writePeople(_ people: [WidgetPersonSnapshot]) {
        guard !people.isEmpty else {
            defaults.removeObject(forKey: WidgetSnapshot.peopleStoreKey)
            return
        }
        do {
            defaults.set(try encoder.encode(people), forKey: WidgetSnapshot.peopleStoreKey)
        } catch {
            logger.error("widget people encode failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func writeSnapshot(_ snapshot: WidgetSnapshot?) {
        guard let snapshot else {
            defaults.removeObject(forKey: WidgetSnapshot.storeKey)
            return
        }
        do {
            let data = try encoder.encode(snapshot)
            defaults.set(data, forKey: WidgetSnapshot.storeKey)
        } catch {
            logger.error("widget snapshot encode failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}

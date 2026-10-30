import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Moves the Keychain items that builds up to v1.3.0 saved without a service into `SecureStore`,
/// whose reads fall back to them until then. Such an item opens only while the phone is unlocked,
/// so a locked launch leaves the flag unset and runs this again once protected data is available,
/// in the same process, as unlocking resumes it.
enum BareKeychainItemMoveMigration {
    private static let doneKey = "BareKeychainItemMoveMigration.v1.done"
    private static var waitingForReadableData: (center: NotificationCenter, observer: any NSObjectProtocol)?

    #if os(iOS)
    static let readableAgain = UIApplication.protectedDataDidBecomeAvailableNotification
    #elseif os(macOS)
    static let readableAgain = NSApplication.didBecomeActiveNotification
    #endif

    static let v13Keys = [
        AppConstants.KeychainKeys.studentId, AppConstants.KeychainKeys.password,
        AppConstants.KeychainKeys.libraryUsername, AppConstants.KeychainKeys.libraryPassword,
        AppConstants.KeychainKeys.libraryToken, AppConstants.KeychainKeys.libraryTokenExpiry,
    ]

    static func runIfNeeded(
        defaults: UserDefaults = .standard, center: NotificationCenter = .default, keys: [String] = v13Keys
    ) {
        if let waiting = waitingForReadableData { waiting.center.removeObserver(waiting.observer) }
        waitingForReadableData = nil
        guard !defaults.bool(forKey: doneKey) else { return }
        guard keys.map(moveBareItems(forKey:)).allSatisfy({ $0 }) else {
            let observer = center.addObserver(forName: readableAgain, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { runIfNeeded(defaults: defaults, center: center, keys: keys) }
            }
            waitingForReadableData = (center, observer)
            return
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Whether none of the key's bare items is left. The newest goes first, so a value saved since
    /// or a newer bare item wins over an older one; an item that cannot be listed, read or saved now
    /// stays for the next run.
    private static func moveBareItems(forKey key: String) -> Bool {
        guard let items = SecureStore.legacyItems(key: key) else { return false }
        return items.map { item in
            do {
                guard let value = try SecureStore.readLegacyItem(item) else { return true }
                if try SecureStore.loadIfReadable(key: key) == nil { try SecureStore.save(value, forKey: key) }
            } catch {
                return false
            }
            SecureStore.deleteLegacyItem(item)
            return true
        }.allSatisfy { $0 }
    }
}

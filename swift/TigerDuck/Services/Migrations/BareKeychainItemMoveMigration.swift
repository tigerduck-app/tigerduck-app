import Foundation
import Security
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Moves the Keychain items that builds up to v1.3.0 saved without a service into `SecureStore`,
/// which no longer reads them. Such an item opens only while the phone is unlocked, so a locked
/// launch leaves the flag unset and runs this again once protected data is available, in the same
/// process, as unlocking resumes it.
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

    /// Whether none of the key's bare items is left. A newer value already in `SecureStore` wins
    /// over a bare item; one that cannot be read or saved now stays for the next run.
    private static func moveBareItems(forKey key: String) -> Bool {
        SecureStore.legacyItems(key: key).map { item in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecValuePersistentRef as String: item,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecItemNotFound:
                return true
            case errSecSuccess:
                guard let value = result as? Data else { return false }
                do {
                    if try SecureStore.loadIfReadable(key: key) == nil { try SecureStore.save(value, forKey: key) }
                } catch {
                    return false
                }
                SecureStore.deleteLegacyItem(item)
                return true
            default:
                return false
            }
        }.allSatisfy { $0 }
    }
}

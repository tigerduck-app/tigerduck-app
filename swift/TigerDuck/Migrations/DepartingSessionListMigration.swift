import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Wraps a single saved departing session in a one-entry list, so its pending unregister survives
/// the per-backend format and is still retried.
enum DepartingSessionListMigration {
    private static let doneKey = "DepartingSessionListMigration.v1.done"
    private static var waitingForReadableData: (center: NotificationCenter, observer: any NSObjectProtocol, run: () -> Void)?

    #if os(iOS)
    static let readableAgain = UIApplication.protectedDataDidBecomeAvailableNotification
    #elseif os(macOS)
    static let readableAgain = NSApplication.didBecomeActiveNotification
    #endif

    /// A Keychain it cannot read now runs it again once protected data is readable, in this
    /// process, before a sign-out could write a list over the earlier object.
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        center: NotificationCenter = .default,
        read: @escaping () throws -> String? = {
            try KeychainManager.loadStringIfReadable(key: AuthTokenManager.departingSessionKey)
        },
        write: @escaping (String) -> Bool = {
            KeychainManager.saveStringReportingSuccess(key: AuthTokenManager.departingSessionKey, value: $0)
        }
    ) {
        if let waiting = waitingForReadableData { waiting.center.removeObserver(waiting.observer) }
        waitingForReadableData = nil
        guard !defaults.bool(forKey: doneKey) else { return }
        let stored: String?
        do {
            stored = try read()
        } catch {
            let observer = center.addObserver(forName: readableAgain, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { waitingForReadableData?.run() }
            }
            waitingForReadableData = (center, observer, { runIfNeeded(defaults: defaults, center: center, read: read, write: write) })
            return
        }
        if let stored, stored.hasPrefix("{") {
            guard write("[" + stored + "]") else { return }
        }
        defaults.set(true, forKey: doneKey)
    }
}

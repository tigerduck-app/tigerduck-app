import Foundation
import UIKit
import os

/// Whether the phone has been unlocked since it started. Until then iOS keeps the app's files, its
/// `UserDefaults` and its after-first-unlock Keychain items closed, and `UserDefaults` answers as if
/// nothing were stored.
nonisolated enum FirstUnlock {
    /// Writes a file of the protection class those default to. A new file's key is wrapped in its
    /// class key, which iOS has only after that unlock, so the write fails until then, where a read
    /// could not tell a closed file from a missing one.
    static func hasHappened(probe: URL = URL.temporaryDirectory.appending(path: "first-unlock-probe")) -> Bool {
        (try? Data().write(to: probe, options: .completeFileProtectionUntilFirstUserAuthentication)) != nil
    }
}

private nonisolated let launchLogger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Launch")

/// What the app builds from stored data, held back in a launch before ``FirstUnlock``. A silent
/// push, a Live Activity start or a Watch message can launch the app then, and a build would take
/// the empty preferences for a fresh install (https://github.com/tigerduck-app/tigerduck-app/issues/680).
/// It is built once: at the unlock, at the next return to the app, or when a scene first reads
/// ``value``, since a scene appears only on an unlocked phone.
@MainActor
final class AfterFirstUnlock<Value> {
    private let make: () -> Value
    private let center: NotificationCenter
    private var built: Value?
    private var waiting: [(Value) -> Void] = []
    private var observers: [NSObjectProtocol] = []

    init(
        hasUnlocked: Bool = FirstUnlock.hasHappened(),
        center: NotificationCenter = .default,
        make: @escaping () -> Value
    ) {
        self.make = make
        self.center = center
        guard !hasUnlocked else {
            _ = value
            return
        }
        launchLogger.notice("Held back until the first unlock")
        // An unlock may come while the app is suspended, so a return to the app builds it too.
        observers = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.value }
            }
        }
    }

    var value: Value {
        if let built { return built }
        let value = make()
        built = value
        if !observers.isEmpty { launchLogger.notice("Built after the first unlock") }
        for observer in observers { center.removeObserver(observer) }
        observers = []
        let owed = waiting
        waiting = []
        for work in owed { work(value) }
        return value
    }

    /// Runs `work` with the built value: now, or once it is built.
    func whenBuilt(_ work: @escaping (Value) -> Void) {
        if let built { work(built) } else { waiting.append(work) }
    }
}

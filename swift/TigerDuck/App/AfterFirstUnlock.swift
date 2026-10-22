import Foundation
import UIKit
import os

/// Whether the phone has been unlocked since it started. Until then iOS keeps the app's files, its
/// `UserDefaults` and its after-first-unlock Keychain items closed, and `UserDefaults` answers as if
/// nothing were stored. See docs/decisions/0024-launch-before-first-unlock.md.
nonisolated enum FirstUnlock {
    /// Writes a file of the protection class those default to. A new file's key is wrapped in its
    /// class key, which iOS has only after that unlock, so the write fails until then, where a read
    /// could not tell a closed file from a missing one.
    static func hasHappened(
        probe: URL = URL.temporaryDirectory.appending(path: "first-unlock-probe"),
        write: (Data, URL, Data.WritingOptions) throws -> Void = { try $0.write(to: $1, options: $2) }
    ) -> Bool {
        (try? write(Data(), probe, .completeFileProtectionUntilFirstUserAuthentication)) != nil
    }

    /// which an install's first launch sets. A process that started before the first unlock may keep
    /// an empty copy after it, so a no comes only after `synchronize()` asked storage once more.
    static func storedDataReadsBack(defaults: UserDefaults = .standard) -> Bool {
        let key = AppConstants.UserDefaultsKeys.appHasBeenInstalled
        if defaults.bool(forKey: key) { return true }
        defaults.synchronize()
        return defaults.bool(forKey: key)
    }
}

nonisolated let launchLogger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Launch")

@MainActor
final class AfterFirstUnlock<Value> {
    private let make: () -> Value
    private let storedDataReadsBack: () -> Bool
    private let endProcess: () -> Void
    private let center: NotificationCenter
    private var built: Value?
    private var waiting: [(Value) -> Void] = []
    private var observers: [NSObjectProtocol] = []

    init(
        hasUnlocked: Bool = FirstUnlock.hasHappened(),
        storedDataReadsBack: @escaping () -> Bool = { FirstUnlock.storedDataReadsBack() },
        endProcess: @escaping () -> Void = { exit(0) },
        center: NotificationCenter = .default,
        make: @escaping () -> Value
    ) {
        self.make = make
        self.storedDataReadsBack = storedDataReadsBack
        self.endProcess = endProcess
        self.center = center
        launchLogger.notice("First unlock had happened: \(hasUnlocked, privacy: .public)")
        guard !hasUnlocked else {
            build()
            return
        }
        observers = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.buildHeldBack() }
            }
        }
    }

    var value: Value {
        if let built { return built }
        if let value = buildHeldBack() { return value }
        preconditionFailure("endProcess returned, and a scene would draw from unread data")
    }

    func whenBuilt(_ work: @escaping (Value) -> Void) {
        if let built { work(built) } else { waiting.append(work) }
    }

    private func buildHeldBack() -> Value? {
        if let built { return built }
        guard storedDataReadsBack() else {
            let unlocked = FirstUnlock.hasHappened()
            let background = UIApplication.shared.applicationState == .background
            launchLogger.error("Stored data does not read back in a held-back launch; ending the process (unlocked: \(unlocked, privacy: .public), background: \(background, privacy: .public))")
            endProcess()
            return nil
        }
        launchLogger.notice("Built after the first unlock")
        return build()
    }

    @discardableResult
    private func build() -> Value {
        let value = make()
        built = value
        for observer in observers { center.removeObserver(observer) }
        observers = []
        let owed = waiting
        waiting = []
        for work in owed { work(value) }
        return value
    }
}

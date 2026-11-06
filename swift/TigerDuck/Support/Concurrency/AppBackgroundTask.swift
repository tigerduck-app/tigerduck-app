import Foundation
#if os(iOS)
import UIKit
#endif

/// A UIKit background task. A Mac app is not suspended in the background, so only iOS starts one.
final class AppBackgroundTask {
    /// Starts one named `name` and returns what ends it.
    nonisolated static func begin(named name: String) async -> @Sendable () async -> Void {
        #if os(iOS)
        let task = await AppBackgroundTask(named: name)
        return { await task.end() }
        #else
        return {}
        #endif
    }

    #if os(iOS)
    private var id = UIBackgroundTaskIdentifier.invalid
    private(set) var isExpired = false

    init(named name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.isExpired = true
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
    #endif
}

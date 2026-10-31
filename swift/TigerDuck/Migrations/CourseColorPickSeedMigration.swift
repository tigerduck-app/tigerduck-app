import Foundation
#if os(iOS)
import UIKit
#endif

enum CourseColorPickSeedMigration {
    private static let doneKey = "CourseColorPickSeedMigration.v1.done"

    static func runIfNeeded(files: CourseColorFiles = CourseColorStore.shared.files, center: NotificationCenter = .default) {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        guard let colors = files.loadCourseColorMapIfReadable() else {
            return runAgainOnceReadable(files: files, center: center)
        }
        files.savePickedCourseColors(files.loadPickedCourseColors().union(colors.keys))
        AppUserDefaults.standard.set(true, forKey: doneKey)
    }

    /// A locked phone keeps the map unreadable, and unlocking resumes this process rather than
    /// launching again. Both notifications are watched, as a resumed process can miss the first.
    /// Like the seed at launch it counts every colour in the map as picked, so one assigned
    /// automatically before the unlock is counted too; a sign-out then only warns about it.
    private static func runAgainOnceReadable(files: CourseColorFiles, center: NotificationCenter) {
        #if os(iOS)
        let retry = Retry()
        retry.observers = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard !retry.observers.isEmpty else { return }
                    retry.observers.forEach(center.removeObserver)
                    retry.observers = []
                    runIfNeeded(files: files, center: center)
                }
            }
        }
        #endif
    }

    private final class Retry {
        var observers: [any NSObjectProtocol] = []
    }
}

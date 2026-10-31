import Foundation
import os
import TigerDuckCore
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class WidgetSnapshotWriter {
    private let store: WidgetSnapshotStore
    private let coordinator: WidgetReloadCoordinator
    private let isLoggedIn: @MainActor () -> Bool
    private let accentColorHex: @MainActor () -> Int
    private let courseProvider: CanonicalCourseProvider
    private let courses: CourseStore
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private var owesForcedReload = false
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "WidgetWriter")


    convenience init(
        appState: AppState,
        courses: CourseStore? = nil,
        store: WidgetSnapshotStore? = nil,
        coordinator: WidgetReloadCoordinator? = nil,
        courseProvider: CanonicalCourseProvider? = nil
    ) {
        self.init(
            isLoggedIn: { appState.authService.hasStoredCredentials },
            accentColorHex: { appState.accentColorHex },
            courses: courses,
            store: store,
            coordinator: coordinator,
            courseProvider: courseProvider
        )
    }

    init(
        isLoggedIn: @escaping @MainActor () -> Bool,
        accentColorHex: @escaping @MainActor () -> Int,
        courses: CourseStore? = nil,
        store: WidgetSnapshotStore? = nil,
        coordinator: WidgetReloadCoordinator? = nil,
        courseProvider: CanonicalCourseProvider? = nil,
        isProtectedDataAvailable: (@MainActor () -> Bool)? = nil
    ) {
        #if os(iOS)
        self.isProtectedDataAvailable = isProtectedDataAvailable ?? { UIApplication.shared.isProtectedDataAvailable }
        #else
        self.isProtectedDataAvailable = isProtectedDataAvailable ?? { true }
        #endif
        self.isLoggedIn = isLoggedIn
        self.accentColorHex = accentColorHex
        self.courses = courses ?? .shared
        self.store = store ?? WidgetSnapshotStore()
        self.coordinator = coordinator ?? WidgetReloadCoordinator()
        self.courseProvider = courseProvider ?? CanonicalCourseProvider()
    }

    private static let outsideTermHorizonDays = 366 + 7

    static func quietDayKeys() -> Set<String> {
        let store = AcademicCalendarStore.shared
        return quietDayKeys(calendar: store.calendar, optedIn: store.optedInHolidayIDs, now: AppClock.now())
    }

    static func quietDayKeys(calendar: AcademicCalendar, optedIn: Set<Int>, now: Date) -> Set<String> {
        calendar.quietDays(optedIn: optedIn).quietDayKeys(from: now, days: outsideTermHorizonDays)
    }

    /// An unchanged snapshot is neither written nor reloaded: this runs on every return to the
    /// app and every data change, and each reload spends the widgets' budget.
    func regenerate(forceReload: Bool = false) {
        guard isProtectedDataAvailable() else {
            owesForcedReload = owesForcedReload || forceReload
            return
        }
        let forceReload = forceReload || owesForcedReload
        owesForcedReload = false
        let courses = courseProvider.currentCourses()
        let customNames = self.courses.loadCourseCustomNamesFlat()
        let colorMap = CourseColorStore.shared.files.loadCourseColorMap()
        let snapshot = WidgetSnapshotBuilder.build(
            .init(
                courses: courses,
                customNames: customNames,
                colorMap: colorMap,
                isLoggedIn: isLoggedIn(),
                accentColorHex: UInt32(bitPattern: Int32(truncatingIfNeeded: accentColorHex())),
                now: AppClock.now(),
                quietDayKeys: Self.quietDayKeys(),
                changes: .cached
            )
        )
        if !forceReload, let stored = store.readSnapshot(), Self.hasSameContent(snapshot, as: stored) {
            return
        }
        store.writeSnapshot(snapshot)
        coordinator.requestReload()
    }

    /// this one asked for it or an earlier change did. A sync trigger's handler calls it before it
    /// answers the push, after which iOS may suspend the app before the debounce ends.
    func regenerateAndReloadNow() {
        regenerate()
        coordinator.reloadNowIfPending()
    }

    static func hasSameContent(_ snapshot: WidgetSnapshot, as other: WidgetSnapshot) -> Bool {
        var candidate = snapshot
        candidate.generatedAt = other.generatedAt
        return candidate == other
    }
}

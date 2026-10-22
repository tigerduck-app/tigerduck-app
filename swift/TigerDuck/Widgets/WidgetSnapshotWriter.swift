import Foundation
import os
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
    private let cache: DataCache
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private var owesForcedReload = false
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "WidgetWriter")

    private var observers: [NSObjectProtocol] = []

    convenience init(
        appState: AppState,
        cache: DataCache? = nil,
        store: WidgetSnapshotStore? = nil,
        coordinator: WidgetReloadCoordinator? = nil,
        courseProvider: CanonicalCourseProvider? = nil
    ) {
        self.init(
            isLoggedIn: { appState.authService.hasStoredCredentials },
            accentColorHex: { appState.accentColorHex },
            cache: cache,
            store: store,
            coordinator: coordinator,
            courseProvider: courseProvider
        )
    }

    init(
        isLoggedIn: @escaping @MainActor () -> Bool,
        accentColorHex: @escaping @MainActor () -> Int,
        cache: DataCache? = nil,
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
        self.cache = cache ?? .shared
        self.store = store ?? WidgetSnapshotStore()
        self.coordinator = coordinator ?? WidgetReloadCoordinator()
        self.courseProvider = courseProvider ?? CanonicalCourseProvider()
        attachObservers()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private static let outsideTermHorizonDays = 366 + 7

    static func quietDayKeys() -> Set<String> {
        let store = AcademicCalendarStore.shared
        return quietDayKeys(calendar: store.calendar, optedIn: store.optedInHolidayIDs, now: AppClock.now())
    }

    static func quietDayKeys(calendar: AcademicCalendar, optedIn: Set<Int>, now: Date) -> Set<String> {
        var keys: Set<String> = []
        let today = AcademicCalendar.startOfDay(now)
        for offset in 0..<outsideTermHorizonDays {
            guard let day = AcademicCalendar.calendar.date(byAdding: .day, value: offset, to: today),
                  !calendar.isInSession(on: day)
            else { continue }
            keys.insert(WidgetTimelineDerivation.dateKey(for: day))
        }
        for holiday in calendar.holidays {
            var day = AcademicCalendar.startOfDay(holiday.start)
            let last = AcademicCalendar.startOfDay(holiday.end)
            while day <= last {
                if calendar.suppressesClasses(on: day, optedIn: optedIn) {
                    keys.insert(WidgetTimelineDerivation.dateKey(for: day))
                }
                guard let next = AcademicCalendar.calendar.date(
                    byAdding: .day, value: 1, to: day
                ) else { break }
                day = next
            }
        }
        return keys
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
        let customNames = cache.loadCourseCustomNamesFlat()
        let colorMap = cache.loadCourseColorMap()
        let snapshot = WidgetSnapshotBuilder.build(
            .init(
                courses: courses,
                customNames: customNames,
                colorMap: colorMap,
                isLoggedIn: isLoggedIn(),
                accentColorHex: UInt32(bitPattern: Int32(truncatingIfNeeded: accentColorHex())),
                now: AppClock.now(),
                quietDayKeys: Self.quietDayKeys()
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

    private func attachObservers() {
        let center = NotificationCenter.default
        var names: [(name: Notification.Name, forceReload: Bool)] = [
            (AppConstants.dataDidUpdate, false),
            (AppConstants.languageDidChange, true),
            (AppConstants.courseSkipStateDidChange, false),
            (AppConstants.holidayNotifyDidChange, false),
            (AppConstants.courseColorMapDidChange, false),
            (AppConstants.accentColorDidChange, false),
            (NSLocale.currentLocaleDidChangeNotification, true),
        ]
        #if DEBUG
        names.append((DebugClockController.didChangeNotification, false))
        #endif
        for (name, forceReload) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.regenerate(forceReload: forceReload)
                }
            }
            observers.append(token)
        }
    }
}

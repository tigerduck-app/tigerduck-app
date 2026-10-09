import Foundation
import os

/// Owns the widget snapshot write pipeline. On the app notifications that change
/// widget content (see `attachObservers()`), it rebuilds the snapshot with
/// `WidgetSnapshotBuilder`, writes it to the App Group store and asks
/// `WidgetReloadCoordinator` for a debounced timeline reload.
///
/// The host app creates it and calls `regenerate()` at cold start. Each call
/// rebuilds the whole snapshot, acceptable with the 300 ms debounce. An accent
/// change posts no notification; it shows after the next event or `regenerate()`.
@MainActor
final class WidgetSnapshotWriter {
    private let store: WidgetSnapshotStore
    private let coordinator: WidgetReloadCoordinator
    private let appState: AppState
    private let courseProvider: CanonicalCourseProvider
    private let cache: DataCache
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "WidgetWriter")

    private var observers: [NSObjectProtocol] = []

    // Defaults resolve in the body: under Swift 6 strict concurrency, default
    // argument expressions are nonisolated even on a MainActor init, so the
    // MainActor-isolated `DataCache.shared` and `WidgetReloadCoordinator()` warn there.
    init(
        appState: AppState,
        cache: DataCache? = nil,
        store: WidgetSnapshotStore? = nil,
        coordinator: WidgetReloadCoordinator? = nil,
        courseProvider: CanonicalCourseProvider? = nil
    ) {
        self.appState = appState
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

    /// Every published school holiday, as `yyyy-MM-dd` keys.
    ///
    /// Not windowed to the widget's horizon: only the app writes the snapshot,
    /// and a widget keeps reloading the last one while the app stays closed. A
    /// horizon measured from write time would expire while the snapshot lives
    /// on, and the first holiday past it would render as a class that is not
    /// happening. A term's holidays are a few dozen dates, so the whole
    /// published set is cheaper than that bug.
    private static func quietDayKeys() -> Set<String> {
        let store = AcademicCalendarStore.shared
        let optedIn = store.optedInHolidayIDs
        let calendar = store.calendar
        var keys: Set<String> = []
        for holiday in calendar.holidays {
            var day = AcademicCalendar.startOfDay(holiday.start)
            let last = AcademicCalendar.startOfDay(holiday.end)
            while day <= last {
                // Re-asked per day rather than trusting this holiday alone:
                // an overlapping holiday the user opted into un-suppresses
                // the day, which is `suppressesClasses`'s rule, not ours.
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

    /// Idempotent — call at app cold-start and again whenever you want to
    /// force a fresh snapshot. Observer paths call this internally.
    func regenerate() {
        let courses = courseProvider.currentCourses()
        let customNames = cache.loadCourseCustomNamesFlat()
        let colorMap = cache.loadCourseColorMap()
        let snapshot = WidgetSnapshotBuilder.build(
            .init(
                courses: courses,
                customNames: customNames,
                colorMap: colorMap,
                // Gate on stored credentials, not `isNTUSTLoggedIn`: it flips false when
                // session cookies expire, flashing "Please sign in" although the next sync
                // re-authenticates silently. Same rule as `ntustProtectedAccessState`.
                isLoggedIn: appState.authService.hasStoredCredentials,
                accentColorHex: UInt32(bitPattern: Int32(truncatingIfNeeded: appState.accentColorHex)),
                now: AppClock.now(),
                quietDayKeys: Self.quietDayKeys()
            )
        )
        store.writeSnapshot(snapshot)
        coordinator.requestReload()
    }

    private func attachObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            AppConstants.dataDidUpdate,
            AppConstants.languageDidChange,
            AppConstants.courseSkipStateDidChange,
            AppConstants.holidayNotifyDidChange,
            AppConstants.courseColorMapDidChange,
            NSLocale.currentLocaleDidChangeNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The queue is .main, but strict concurrency still needs a MainActor
                // hop to touch the writer from this closure, so go through a Task.
                Task { @MainActor [weak self] in
                    self?.regenerate()
                }
            }
            observers.append(token)
        }
    }
}

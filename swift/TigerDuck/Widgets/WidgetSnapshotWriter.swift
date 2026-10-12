import Foundation
import os

/// Owns the widget snapshot write pipeline. On the app notifications that change
/// widget content (see `attachObservers()`), it rebuilds the snapshot with
/// `WidgetSnapshotBuilder`, writes it to the App Group store and asks
/// `WidgetReloadCoordinator` for a debounced timeline reload.
///
/// The host app creates it and calls `regenerate()` at cold start. Each call
/// rebuilds the whole snapshot, but writes and reloads only when it changed.
@MainActor
final class WidgetSnapshotWriter {
    private let store: WidgetSnapshotStore
    private let coordinator: WidgetReloadCoordinator
    private let isLoggedIn: @MainActor () -> Bool
    private let accentColorHex: @MainActor () -> Int
    private let courseProvider: CanonicalCourseProvider
    private let cache: DataCache
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
            // Gate on stored credentials, not `isNTUSTLoggedIn`: it flips false when
            // session cookies expire, flashing "Please sign in" although the next sync
            // re-authenticates silently. Same rule as `ntustProtectedAccessState`.
            isLoggedIn: { appState.authService.hasStoredCredentials },
            accentColorHex: { appState.accentColorHex },
            cache: cache,
            store: store,
            coordinator: coordinator,
            courseProvider: courseProvider
        )
    }

    // Defaults resolve in the body: under Swift 6 strict concurrency, default
    // argument expressions are nonisolated even on a MainActor init, so the
    // MainActor-isolated `DataCache.shared` and `WidgetReloadCoordinator()` warn there.
    init(
        isLoggedIn: @escaping @MainActor () -> Bool,
        accentColorHex: @escaping @MainActor () -> Int,
        cache: DataCache? = nil,
        store: WidgetSnapshotStore? = nil,
        coordinator: WidgetReloadCoordinator? = nil,
        courseProvider: CanonicalCourseProvider? = nil
    ) {
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

    /// Idempotent — call at app cold-start and again whenever the widget data may have
    /// changed. Observer paths call this internally. An unchanged snapshot is neither written
    /// nor reloaded, since this runs on every return to the app and every data change and each
    /// reload spends the widgets' budget; `forceReload` reloads it anyway.
    func regenerate(forceReload: Bool = false) {
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

    /// Equal but for `generatedAt`, which every build stamps afresh and no widget reads.
    static func hasSameContent(_ snapshot: WidgetSnapshot, as other: WidgetSnapshot) -> Bool {
        var candidate = snapshot
        candidate.generatedAt = other.generatedAt
        return candidate == other
    }

    private func attachObservers() {
        let center = NotificationCenter.default
        let names: [(name: Notification.Name, forceReload: Bool)] = [
            (AppConstants.dataDidUpdate, false),
            // The widgets render their text in the new language, which no snapshot field
            // holds, so these two reload even when the snapshot is unchanged.
            (AppConstants.languageDidChange, true),
            (AppConstants.courseSkipStateDidChange, false),
            (AppConstants.holidayNotifyDidChange, false),
            (AppConstants.courseColorMapDidChange, false),
            (AppConstants.accentColorDidChange, false),
            (NSLocale.currentLocaleDidChangeNotification, true),
        ]
        for (name, forceReload) in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // The queue is .main, but strict concurrency still needs a MainActor
                // hop to touch the writer from this closure, so go through a Task.
                Task { @MainActor [weak self] in
                    self?.regenerate(forceReload: forceReload)
                }
            }
            observers.append(token)
        }
    }
}

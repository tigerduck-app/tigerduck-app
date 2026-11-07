import Foundation
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
    private let importedPeople: @MainActor () -> [ImportedPerson]
    private let schoolCalendar: @MainActor () -> (calendar: AcademicCalendar, optedIn: Set<Int>)
    private var owesForcedReload = false


    convenience init(
        app: AppEnvironment,
        courses: CourseStore? = nil,
        store: WidgetSnapshotStore? = nil,
        coordinator: WidgetReloadCoordinator? = nil,
        courseProvider: CanonicalCourseProvider? = nil
    ) {
        self.init(
            isLoggedIn: { app.authService.hasStoredCredentials },
            accentColorHex: { app.preferences.accentColorHex },
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
        isProtectedDataAvailable: (@MainActor () -> Bool)? = nil,
        importedPeople: @escaping @MainActor () -> [ImportedPerson] = { ImportedClassTableStore.shared.people },
        schoolCalendar: @escaping @MainActor () -> (calendar: AcademicCalendar, optedIn: Set<Int>) = {
            (AcademicCalendarStore.shared.calendar, AcademicCalendarStore.shared.optedInHolidayIDs)
        }
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
        self.importedPeople = importedPeople
        self.schoolCalendar = schoolCalendar
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
        let semester = CourseSelectionService.currentSemesterCode()
        let colorMap = CourseColorStore.shared.files.loadCourseColorMap()
        let now = AppClock.now()
        let (calendar, optedIn) = schoolCalendar()
        let input = WidgetSnapshotBuilder.Input(
            courses: courseProvider.currentCourses(semester: semester),
            customNames: courses.loadCourseCustomNamesFlat(),
            colorMap: colorMap,
            isLoggedIn: isLoggedIn(),
            accentColorHex: UInt32(bitPattern: Int32(truncatingIfNeeded: accentColorHex())),
            now: now,
            quietDayKeys: Self.quietDayKeys(calendar: calendar, optedIn: optedIn, now: now),
            changes: .cached,
            term: calendar.terms.first { $0.code == semester }?.days
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        let people = importedPeople().map { person in
            var friend = input
            friend.courses = person.courses(in: semester)
            friend.customNames = [:]
            friend.quietDayKeys = Self.quietDayKeys(calendar: calendar, optedIn: [], now: now)
            return WidgetPersonSnapshot(
                id: person.id.uuidString, name: person.nickname, snapshot: WidgetSnapshotBuilder.build(friend)
            )
        }
        let storedPeople = store.readPeople()
        let peopleChanged = people.count != storedPeople.count || !zip(people, storedPeople).allSatisfy {
            $0.id == $1.id && $0.name == $1.name && Self.hasSameContent($0.snapshot, as: $1.snapshot)
        }
        let ownChanged = store.readSnapshot().map { !Self.hasSameContent(snapshot, as: $0) } ?? true
        guard forceReload || ownChanged || peopleChanged else { return }
        store.writeSnapshot(snapshot)
        store.writePeople(people)
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

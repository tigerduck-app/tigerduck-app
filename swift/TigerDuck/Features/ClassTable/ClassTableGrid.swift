import Defaults
import Foundation
import TigerDuckCore

@MainActor
@Observable
final class ClassTableGrid {
    typealias CellRole = ClassTableCellRole<CourseStore.Course>

    struct CellRoleKey: Hashable {
        let weekday: Int
        let periodIndex: Int
        let withClubs: Bool
    }

    var courses: [CourseStore.Course] = [] {
        didSet { rebuildLookup() }
    }

    var courseChanges: SchoolCalendar.Changes = SchoolCalendar.changes

    private(set) var clubs: [Int: [ClubOccurrence]] = [:] {
        didSet { invalidateCellRoleCache() }
    }
    @ObservationIgnored let clubFeed: ClubActivities

    private(set) var showsAllPeriods: Bool = Defaults[.alwaysShowAllPeriods]
    @ObservationIgnored var cellRoleCache: [CellRoleKey: CellRole] = [:]
    private var courseLookup: [Int: [String: [CourseStore.Course]]] = [:]
    @ObservationIgnored
    private nonisolated(unsafe) var periodVisibilityTask: Task<Void, Never>?

    @ObservationIgnored var onCoursesChange: () -> Void = {}

    init(clubFeed: ClubActivities = .shared) {
        self.clubFeed = clubFeed
        periodVisibilityTask = Task { [weak self] in
            for await value in Defaults.updates(.alwaysShowAllPeriods, initial: true) {
                guard let self else { return }
                guard value != self.showsAllPeriods else { continue }
                self.showsAllPeriods = value
                self.invalidateCellRoleCache()
            }
        }
    }

    deinit {
        periodVisibilityTask?.cancel()
    }

    func rebuildLookup() {
        var lookup: [Int: [String: [CourseStore.Course]]] = [:]
        for course in courses {
            for (weekday, periods) in course.schedule {
                for period in periods {
                    lookup[weekday, default: [:]][period, default: []].append(course)
                }
            }
        }
        courseLookup = lookup
        cellRoleCache.removeAll(keepingCapacity: true)
        onCoursesChange()
    }

    func showClubs(on days: [Date]) {
        let weekdays = Dictionary(days.map { (TaipeiTime.dayKey(for: $0), $0.scheduleWeekday) }) { first, _ in first }
        let shown = Dictionary(grouping: clubFeed.occurrences(on: days)) { weekdays[$0.day] ?? 0 }
        if shown != clubs { clubs = shown }
    }

    func invalidateCellRoleCache() {
        cellRoleCache.removeAll(keepingCapacity: true)
    }

    var totalCredits: Double {
        courses.reduce(0) { $0 + $1.credits }
    }

    func activeWeekdays(withClubs: Bool) -> [Int] {
        var days = Set<Int>()
        for course in courses {
            for day in course.schedule.keys { days.insert(day) }
        }
        if withClubs { days.formUnion(clubs.filter { !$0.value.isEmpty }.keys) }
        var result = Array(1...5)
        if days.contains(6) { result.append(6) }
        if days.contains(7) { result.append(7) }
        return result.sorted()
    }

    func activePeriods(withClubs: Bool) -> [TimetablePeriod] {
        var periodIds = Set(AppConstants.Periods.defaultVisible)
        if showsAllPeriods {
            periodIds.formUnion(AppConstants.Periods.chronologicalOrder)
        }
        for course in courses {
            for periods in course.schedule.values {
                for p in periods { periodIds.insert(p) }
            }
        }
        if withClubs {
            for club in clubs.values.joined() {
                for period in TimetablePeriod.all {
                    guard let times = period.minutes, club.start < times.end, times.start < club.end else { continue }
                    periodIds.insert(period.id)
                }
            }
        }
        let order = AppConstants.Periods.chronologicalOrder
        return order.filter { periodIds.contains($0) }.compactMap { TimetablePeriod.byId[$0] }
    }

    func course(for weekday: Int, period: String) -> CourseStore.Course? {
        courseLookup[weekday]?[period]?.first
    }

    func courses(for weekday: Int, period: String) -> [CourseStore.Course] {
        courseLookup[weekday]?[period] ?? []
    }

    func cellRole(weekday: Int, periodIndex: Int, withClubs: Bool) -> CellRole {
        let key = CellRoleKey(weekday: weekday, periodIndex: periodIndex, withClubs: withClubs)
        if let cached = cellRoleCache[key] { return cached }
        let role = ClassTableLayout.cellRole(
            courses: courses,
            periodIds: activePeriods(withClubs: withClubs).map(\.id),
            weekday: weekday,
            periodIndex: periodIndex,
            keyOf: { $0.courseNo },
            scheduleOf: { $0.schedule }
        )
        cellRoleCache[key] = role
        return role
    }

    func tripleConflict(adding candidate: CourseStore.Course) -> TripleConflictError? {
        for (weekday, periodIds) in candidate.schedule {
            for pid in periodIds {
                let existing = courses(for: weekday, period: pid)
                if existing.count >= 2 {
                    return TripleConflictError(
                        weekday: weekday,
                        periodId: pid,
                        newCourseName: candidate.displayName,
                        existingA: existing[0],
                        existingB: existing[1]
                    )
                }
            }
        }
        return nil
    }
}

struct TripleConflictError: Identifiable {
    let id = UUID()
    let weekday: Int
    let periodId: String
    let newCourseName: String
    let existingA: CourseStore.Course
    let existingB: CourseStore.Course
}

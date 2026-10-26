import Foundation

/// A class period on one weekday. `day` counts from 1 for Monday, as
/// `CourseLookupService.parseNodeToSchedule` does.
nonisolated struct CourseSlot: Hashable {
    let day: Int
    let period: String
}

/// A timetable course, as the search compares results with it.
struct CourseSearchTableCourse {
    let courseNo: String
    let name: String
    let slots: Set<CourseSlot>
}

/// The Add Course filters. They last for one sheet, so nothing here is stored.
nonisolated struct CourseSearchFilters: Hashable {
    nonisolated enum Level: Hashable, CaseIterable {
        case all, undergraduate, graduate
    }

    var hideConflicts = true
    var department: String?
    var level = Level.all
    var dimension: String?
    var periods: Set<CourseSlot> = []
    var generalOnly = false
    var englishTaught = false
    var intensiveOnly = false
    var excludeAlliance = false

    var isDefault: Bool { self == Self() }

    /// The filters the catalog search applies. The others only narrow its results in the view,
    /// so a change to them runs no search.
    var searched: Self {
        var sent = self
        sent.hideConflicts = Self().hideConflicts
        sent.periods = []
        return sent
    }
}

enum CourseSearch {
    static let languages = ["zh", "en"]
    static let gridDays = Array(1...6)

    private nonisolated static let courseNoPattern = #"^[A-Za-z0-9]+$"#
    private nonisolated static let hansHantTransform = StringTransform(rawValue: "Hans-Hant")
    // A course number's third character, as the school's level filters read it
    // (`local_match` in api-poc/api/ntust/course_query.py).
    private nonisolated static let undergraduateLevels: Set<Character> = ["1", "2", "3", "4", "G"]
    private nonisolated static let graduateLevels: Set<Character> = ["5", "6", "7", "8", "9"]

    /// Each language's rows that pass the filters and match, in catalog order; a language that
    /// found nothing has no entry. A query of letters and digits is first a course-number prefix,
    /// and the name and teacher are matched only when no course number starts with it.
    nonisolated static func search(
        _ query: String,
        in catalogs: [String: [CourseCatalog.Course]],
        filters: CourseSearchFilters
    ) -> [String: [CourseSearchResult]] {
        if query.range(of: courseNoPattern, options: .regularExpression) != nil {
            let prefix = query.uppercased()
            let found = rows(in: catalogs, filters) { _, course in course.numberKey.hasPrefix(prefix) }
            if !found.isEmpty { return found }
        }
        // The zh names are in traditional characters, so simplified input is converted.
        let zhQuery = query.applyingTransform(hansHantTransform, reverse: false) ?? query
        let needles = (zh: Array(zhQuery.lowercased().utf8), other: Array(query.lowercased().utf8))
        return rows(in: catalogs, filters) { language, course in
            holds(course.textKey, language == "zh" ? needles.zh : needles.other)
        }
    }

    private nonisolated static func rows(
        in catalogs: [String: [CourseCatalog.Course]],
        _ filters: CourseSearchFilters,
        where matches: (_ language: String, CourseCatalog.Course) -> Bool
    ) -> [String: [CourseSearchResult]] {
        var found: [String: [CourseSearchResult]] = [:]
        for (language, courses) in catalogs {
            let rows = courses.compactMap { admits($0, filters) && matches(language, $0) ? $0.row : nil }
            if !rows.isEmpty { found[language] = rows }
        }
        return found
    }

    // UTF-8 never starts a character inside another, so a byte match is a text match.
    private nonisolated static func holds(_ text: [UInt8], _ needle: [UInt8]) -> Bool {
        text.withUnsafeBytes { text in
            needle.withUnsafeBytes { memmem(text.baseAddress, text.count, $0.baseAddress, $0.count) != nil }
        }
    }

    nonisolated static func admits(_ course: CourseCatalog.Course, _ filters: CourseSearchFilters) -> Bool {
        let row = course.row
        let level = course.numberKey.dropFirst(2).first ?? " "
        let levelMatches = switch filters.level {
        case .all: true
        case .undergraduate: undergraduateLevels.contains(level)
        case .graduate: graduateLevels.contains(level)
        }
        return levelMatches
            && (filters.department.map { course.numberKey.hasPrefix($0.uppercased()) } ?? true)
            && (filters.dimension.map { row.Dimension == $0 } ?? true)
            && (!filters.generalOnly || !(row.Dimension ?? "").isEmpty)
            && (!filters.englishTaught || course.isEnglishTaught)
            && (!filters.intensiveOnly || course.isIntensive)
            && (!filters.excludeAlliance || !course.isAlliance)
    }

    /// The filter lists of the term, with each name in both languages. A list only one language
    /// has keeps that language's names for both.
    static func options(_ catalogs: [String: CourseCatalog]) -> CourseSearchOptions {
        guard let zh = catalogs["zh"] ?? catalogs["en"] else { return CourseSearchOptions() }
        let en = catalogs["en"] ?? zh
        func list(_ named: [CourseCatalog.Named], english: [CourseCatalog.Named]) -> [CourseSearchOptions.Option] {
            let english = Dictionary(english.map { ($0.no, $0.name) }, uniquingKeysWith: { first, _ in first })
            return named.map { .init(code: $0.no, name: $0.name, englishName: english[$0.no] ?? $0.name) }
        }
        let enColleges = Dictionary(en.colleges.map { ($0.no, $0) }, uniquingKeysWith: { first, _ in first })
        return CourseSearchOptions(
            colleges: zh.colleges.map { college in
                CourseSearchOptions.College(
                    name: college.name,
                    englishName: enColleges[college.no]?.name ?? college.name,
                    departments: list(college.departments, english: enColleges[college.no]?.departments ?? [])
                )
            },
            dimensions: list(zh.dimensions, english: en.dimensions)
        )
    }

    /// The rows to show: the primary language's, then the courses only another language found,
    /// with each course's name in the other language.
    static func shown(
        _ results: [String: [CourseSearchResult]],
        primary: String
    ) -> (rows: [CourseSearchResult], otherNames: [String: String]) {
        let mine = results[primary] ?? []
        let other = languages.filter { $0 != primary }.flatMap { results[$0] ?? [] }
        let mineNos = Set(mine.map(\.CourseNo))
        let otherNames = Dictionary(other.map { ($0.CourseNo, $0.CourseName) }, uniquingKeysWith: { first, _ in first })
        return (mine + other.filter { !mineNos.contains($0.CourseNo) }, otherNames)
    }

    static func slots(_ schedule: [Int: [String]]) -> Set<CourseSlot> {
        Set(schedule.flatMap { day, periods in periods.map { CourseSlot(day: day, period: $0) } })
    }

    /// The names of the timetable courses a result clashes with, or nil when the device-only
    /// filters hide it. A course already in the timetable clashes with nothing. With periods
    /// picked, a course must meet in them only, so one without class times is hidden.
    static func visibleConflicts(
        courseNo: String,
        schedule: [Int: [String]],
        table: [CourseSearchTableCourse],
        filters: CourseSearchFilters
    ) -> [String]? {
        let slots = slots(schedule)
        if !filters.periods.isEmpty, slots.isEmpty || !slots.isSubset(of: filters.periods) {
            return nil
        }
        guard !table.contains(where: { $0.courseNo == courseNo }) else { return [] }
        let names = table.filter { !$0.slots.isDisjoint(with: slots) }.map(\.name)
        return filters.hideConflicts && !names.isEmpty ? nil : names
    }

    static func freeSlots(busy: Set<CourseSlot>) -> Set<CourseSlot> {
        Set(gridDays.flatMap { day in
            AppConstants.Periods.chronologicalOrder.map { CourseSlot(day: day, period: $0) }
        }).subtracting(busy)
    }

    /// The colleges with only the departments whose code or name holds `query`, ignoring case.
    static func colleges(
        _ colleges: [CourseSearchOptions.College],
        matching query: String
    ) -> [CourseSearchOptions.College] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return colleges }
        return colleges.compactMap { college in
            let departments = college.departments.filter { department in
                [department.code, department.name, department.englishName]
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
            guard !departments.isEmpty else { return nil }
            return .init(name: college.name, englishName: college.englishName, departments: departments)
        }
    }
}

/// Where the periods grid's cells sit: from `origin`, past the label column and the header row,
/// in equal cells of `cell`, weekdays across and periods down.
struct PeriodGridGeometry {
    let origin: CGPoint
    let cell: CGSize

    private static let periods = AppConstants.Periods.chronologicalOrder

    /// The cells the line from `start` to `end` crosses, in order, leaving out what falls outside
    /// the grid. A line through a corner steps diagonally instead of taking a neighbour.
    func slots(from start: CGPoint, to end: CGPoint) -> [CourseSlot] {
        guard cell.width > 0, cell.height > 0 else { return [] }
        let from = (x: (start.x - origin.x) / cell.width, y: (start.y - origin.y) / cell.height)
        let to = (x: (end.x - origin.x) / cell.width, y: (end.y - origin.y) / cell.height)
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        var (column, row) = (Int(from.x.rounded(.down)), Int(from.y.rounded(.down)))
        let last = (column: Int(to.x.rounded(.down)), row: Int(to.y.rounded(.down)))
        let step = (x: dx > 0 ? 1 : -1, y: dy > 0 ? 1 : -1)
        // The fraction of the line at which it next crosses a column or a row boundary.
        var nextX = dx == 0 ? CGFloat.infinity : (CGFloat(column + (dx > 0 ? 1 : 0)) - from.x) / dx
        var nextY = dy == 0 ? CGFloat.infinity : (CGFloat(row + (dy > 0 ? 1 : 0)) - from.y) / dy
        let deltaX = dx == 0 ? CGFloat.infinity : 1 / abs(dx)
        let deltaY = dy == 0 ? CGFloat.infinity : 1 / abs(dy)

        var crossed = [slot(column: column, row: row)]
        for _ in 0..<(abs(last.column - column) + abs(last.row - row)) {
            guard column != last.column || row != last.row else { break }
            let crossesColumn = nextX <= nextY
            let crossesRow = nextY <= nextX
            if crossesColumn {
                column += step.x
                nextX += deltaX
            }
            if crossesRow {
                row += step.y
                nextY += deltaY
            }
            crossed.append(slot(column: column, row: row))
        }
        return crossed.compactMap { $0 }
    }

    private func slot(column: Int, row: Int) -> CourseSlot? {
        guard CourseSearch.gridDays.indices.contains(column), Self.periods.indices.contains(row) else { return nil }
        return CourseSlot(day: CourseSearch.gridDays[column], period: Self.periods[row])
    }
}

/// One drag across the periods grid. The first cell decides whether the drag selects or clears,
/// and every cell it crosses follows.
struct PeriodDrag {
    private var selects: Bool?
    private var last: CGPoint?

    /// Applies the drag to every cell from the previous point to `point`, since a fast drag
    /// reports points several cells apart.
    mutating func move(to point: CGPoint, in grid: PeriodGridGeometry, picked: inout Set<CourseSlot>) {
        for slot in grid.slots(from: last ?? point, to: point) {
            touch(slot, in: &picked)
        }
        last = point
    }

    mutating func touch(_ slot: CourseSlot, in picked: inout Set<CourseSlot>) {
        let selects = self.selects ?? !picked.contains(slot)
        self.selects = selects
        if selects {
            picked.insert(slot)
        } else {
            picked.remove(slot)
        }
    }
}

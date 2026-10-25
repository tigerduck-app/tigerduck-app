import Foundation

/// A class period on one weekday. `day` counts from 1 for Monday, as
/// `CourseLookupService.parseNodeToSchedule` does.
struct CourseSlot: Hashable {
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
struct CourseSearchFilters: Hashable {
    enum Level: Hashable, CaseIterable {
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

    /// The filters the server applies. The others only narrow the results on the device, so a
    /// change to them sends no request.
    var requested: Self {
        var sent = self
        sent.hideConflicts = Self().hideConflicts
        sent.periods = []
        return sent
    }
}

enum CourseSearch {
    static let languages = ["zh", "en"]
    static let gridDays = Array(1...6)

    private static let courseNoPattern = #"^[A-Za-z0-9]+$"#
    private static let hansHantTransform = StringTransform(rawValue: "Hans-Hant")

    /// The request rounds for a query, in order; a round runs only when the ones before it found
    /// nothing. Each round asks in both languages, since a name matches only in its own language.
    static func rounds(for query: String, semester: String, filters: CourseSearchFilters) -> [[CourseSearchRequest]] {
        var rounds: [[CourseSearchRequest]] = []
        if query.range(of: courseNoPattern, options: .regularExpression) != nil,
           let courseNo = courseNoPrefix(query.uppercased(), department: filters.department) {
            rounds.append(languages.map { request(semester, $0, filters, courseNo: courseNo) })
        }
        // The zh service matches traditional characters only, so simplified input is converted.
        let zhQuery = query.applyingTransform(hansHantTransform, reverse: false) ?? query
        let department = filters.department ?? ""
        rounds.append(languages.flatMap { language in
            let text = language == "zh" ? zhQuery : query
            return [
                request(semester, language, filters, courseNo: department, name: text),
                request(semester, language, filters, courseNo: department, teacher: text),
            ]
        })
        return rounds
    }

    /// The narrower of the typed course-number prefix and the department's, or nil when no
    /// course number can start with both.
    static func courseNoPrefix(_ typed: String, department: String?) -> String? {
        guard let department = department?.uppercased() else { return typed }
        if typed.hasPrefix(department) { return typed }
        if department.hasPrefix(typed) { return department }
        return nil
    }

    private static func request(
        _ semester: String,
        _ language: String,
        _ filters: CourseSearchFilters,
        courseNo: String,
        name: String = "",
        teacher: String = ""
    ) -> CourseSearchRequest {
        CourseSearchRequest(
            Semester: semester,
            CourseNo: courseNo,
            CourseName: name,
            CourseTeacher: teacher,
            Dimension: filters.dimension ?? "",
            // `eng` is the English-taught note; `ForeignLanguage` means language classes instead.
            CourseNotes: filters.englishTaught ? "eng" : "",
            CampusNotes: "",
            ForeignLanguage: 0,
            OnlyGeneral: filters.generalOnly ? 1 : 0,
            OnleyNTUST: filters.excludeAlliance ? 1 : 0,
            OnlyMaster: filters.level == .graduate ? 1 : 0,
            OnlyUnderGraduate: filters.level == .undergraduate ? 1 : 0,
            OnlyNode: 0,
            OnlyIntensive: filters.intensiveOnly ? 1 : 0,
            Language: language
        )
    }

    /// `rows` followed by the rows of `new` it lacks. A course number can hold several rows, one
    /// per time slot, so a row is keyed by its number and slot.
    static func merge(_ rows: [CourseSearchResult], _ new: [CourseSearchResult]) -> [CourseSearchResult] {
        var seen = Set<String>()
        return (rows + new).filter { seen.insert("\($0.CourseNo)#\($0.Node ?? "")").inserted }
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

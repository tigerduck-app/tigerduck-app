import Defaults
import Foundation
import TigerDuckCore

@MainActor
@Observable
final class ClassTableViewModel {
    private(set) var currentSemester: String = SchoolTerms.selected(storedPick: Defaults[.classTableSelectedSemester]) {
        didSet {
            guard currentSemester != oldValue else { return }
            reloadFromCache()
        }
    }

    /// The user's own table keeps the term picked on it; someone else's shown table does not.
    func pickSemester(_ semester: String, for signIn: SignIn) {
        guard semester != currentSemester else { return }
        if shownPerson == nil { SchoolAccountKeys.pickSemester(semester, for: signIn) }
        currentSemester = semester
    }

    var assignments: [AssignmentStore.Assignment] = []
    var selection = ClassTableSelection()
    let grid = ClassTableGrid()
    let today: ClassTableToday
    let people: ShownPersonModel
    let editor: ClassTableEditor
    let loader = ClassTableLoader()
    private var terms = OwnTerms(
        options: ClassTableViewModel.semesterOptions(
            including: SchoolTerms.selected(storedPick: Defaults[.classTableSelectedSemester])
        )
    )
    @ObservationIgnored private var storeObservation: StoreObservation?

    private struct OwnTerms {
        var options: [String]
    }

    init(
        isClassDay: @escaping (Date) -> Bool = { _ in true },
        courses: CourseStore = .shared,
        importedTables: ImportedClassTableStore = .shared,
        lookUpImportedTerm: @escaping ShownPersonModel.TermLookup = {
            await SchoolRefresh.importedTerm(semester: $0, courseNos: $1, current: $2)
        }
    ) {
        today = ClassTableToday(isClassDay: isClassDay)
        people = ShownPersonModel(store: importedTables, lookUpTerm: lookUpImportedTerm)
        editor = ClassTableEditor(store: courses)
        editor.owner = self
        loader.owner = self
        grid.onCoursesChange = { [weak self] in self?.refreshCourseColors() }
        storeObservation = StoreObservation(read: { _ = AppDataRevision.current }) { [weak self] in
            self?.reloadFromCache()
        }
    }

    var courseStore: CourseStore { editor.store }

    var courses: [CourseStore.Course] {
        get { grid.courses }
        set { grid.courses = newValue }
    }

    var shownPerson: ImportedPerson? { people.shownPerson }
    var shownTable: ImportedClassTableStore.ShownTable { people.store.shownTable }
    var availableSemesters: [String] { shownPerson?.semesters ?? terms.options }

    /// Keeps the persisted selection selectable even after it ages out of the
    /// catalogue window — a `Picker` whose tag matches no option renders blank.
    static func semesterOptions(including selected: String) -> [String] {
        let options = SchoolTerms.available()
        return options.contains(selected) ? options : options + [selected]
    }

    func refreshSemesterOptions() {
        guard shownPerson == nil else { return }
        terms.options = Self.semesterOptions(including: currentSemester)
    }

    @discardableResult
    func followNewestSemesterIfUnpicked() -> Bool {
        guard shownPerson == nil,
              Defaults[.classTableSelectedSemester] == nil,
              let newest = SchoolTerms.available().first,
              newest != currentSemester else { return false }
        follow(newest)
        return true
    }

    private func follow(_ semester: String) {
        currentSemester = semester
    }

    func displayLabel(for code: String) -> String {
        AcademicTerm.label(of: code)
    }

    func buildCourseList(_ primary: [CourseStore.Course], _ userAdded: [CourseStore.Course]) -> [CourseStore.Course] {
        var merged = primary
        for course in userAdded where !merged.contains(where: { $0.courseNo == course.courseNo }) {
            merged.append(course)
        }
        editor.applyCustomizations(&merged)
        return merged
    }

    func reloadFromCache() {
        if let shownPerson {
            today.reload()
            courses = shownPerson.courses(in: currentSemester)
            grid.courseChanges = SchoolCalendar.changes
            return
        }
        guard !followNewestSemesterIfUnpicked() else { return }
        terms.options = Self.semesterOptions(including: currentSemester)
        editor.reloadMarks()
        TigerDuckTheme.reload()
        today.reload()
        courses = buildCourseList(
            courseStore.loadCourses(semester: currentSemester),
            courseStore.loadUserAddedCourses(semester: currentSemester)
        )
        assignments = AssignmentStore.shared.loadAssignments()
        grid.courseChanges = SchoolCalendar.changes
    }

    func showShownTable() {
        people.showStoredPerson()
        if shownPerson != nil { editor.closeDialogs() }
        let semester = shownPerson?.semester(keeping: currentSemester)
            ?? SchoolTerms.selected(storedPick: Defaults[.classTableSelectedSemester])
        guard semester != currentSemester else {
            reloadFromCache()
            return
        }
        follow(semester)
    }

    func refreshShownPerson() async {
        if await people.refresh(semester: currentSemester) == .lookedUpWhileShown { reloadFromCache() }
    }

    func refreshCourseColors() {
        let shown = shownPerson == nil ? courses : []
        TigerDuckTheme.ensureAssignments(courses: shown + today.courses, for: AccountSession.school.currentSignIn)
    }

    var todayCourses: [CourseStore.Course] {
        shownPerson == nil ? today.todayCourses : []
    }

    var ongoingCourses: [OngoingCourseInfo] {
        today.ongoingCourses(changes: grid.courseChanges)
    }

    func hasAssignment(for courseNo: String) -> Bool {
        shownPerson == nil && assignments.hasUnfinished(for: courseNo)
    }

    func assignmentsFor(courseNo: String) -> [AssignmentStore.Assignment] {
        shownPerson == nil ? assignments.unfinished(for: courseNo) : []
    }

    func presentConflictPicker(courseA: CourseStore.Course, courseB: CourseStore.Course, weekday: Int, periodId: String) {
        selection.conflictPickerTarget = .init(courses: [courseA, courseB], weekday: weekday, periodId: periodId)
    }

    func pickFromConflict(_ course: CourseStore.Course) {
        guard let target = selection.conflictPickerTarget else { return }
        selection.conflictPickerTarget = nil
        selectCourse(course, weekday: target.weekday, periodId: target.periodId)
    }

    func selectOngoing(_ info: OngoingCourseInfo) {
        selection.select(ongoing: info, now: AppClock.now())
    }

    func selectCourse(_ course: CourseStore.Course, weekday: Int, periodId: String) {
        selection.weekday = weekday
        selection.periodId = periodId
        selection.coursePeriods = course.block(weekday: weekday, at: periodId, in: grid.activePeriods.map(\.id))
        selection.date = showsThisWeek ? Self.nextDate(onWeekday: weekday, from: AppClock.now()) : nil
        selection.currentClassSlot = nil
        selection.course = course
    }

    var showsThisWeek: Bool {
        grid.courseChanges.hasAnswered && currentSemester == SchoolTerms.current
    }

    static func nextDate(onWeekday weekday: Int, from today: Date) -> Date {
        let calendar = TaipeiTime.calendar
        let start = calendar.startOfDay(for: today)
        let ahead = (weekday - today.scheduleWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: ahead, to: start) ?? start
    }

    func changedMeeting(of course: CourseStore.Course, weekday: Int, at periodId: String, today: Date) -> CourseTimeSlot? {
        guard showsThisWeek else { return nil }
        let date = Self.nextDate(onWeekday: weekday, from: today)
        let changes = grid.courseChanges
        guard !changes.changes(courseNo: course.courseNo, on: date).isEmpty,
              let block = course.block(weekday: weekday, at: periodId, in: grid.activePeriods.map(\.id))
        else { return nil }
        return CourseTimeSlot.meeting(of: course, periods: block, on: date, changes: changes)
            .flatMap { $0.changes.isEmpty ? nil : $0 }
    }
}

extension SchoolCalendar.Changes {
    var hasAnswered: Bool { !term.isEmpty }
}

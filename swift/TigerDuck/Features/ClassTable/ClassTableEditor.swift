import Defaults
import Foundation

/// The user's edits of their own class table: adding, hiding, renaming and recolouring courses,
/// ignoring a course's assignments and resetting a term. Each edit goes to the stores and then
/// to `sync`. The iPhone and Mac class tables share it through `ClassTableViewModel`.
@MainActor
@Observable
final class ClassTableEditor {
    /// The sheets and alerts an edit opens.
    struct Dialogs {
        var showAddCourse = false
        var showResetConfirm = false
        var showResetFailedAlert = false
        var courseToRename: CourseStore.Course?
        var renameText = ""
        var showRenameAlert = false
        var courseToRecolor: CourseStore.Course?
        var tripleConflictError: TripleConflictError?
    }

    @ObservationIgnored weak var owner: ClassTableViewModel?
    @ObservationIgnored let store: CourseStore
    @ObservationIgnored var sync = ClassTableSync()
    var dialogs = Dialogs()
    var deletedCourseNos: Set<String> = []
    var courseCustomNames: [String: [String: String]] = [:]
    var ignoredAssignmentCourses: Set<String> = []
    var resettingSemesters: Set<String> = []

    init(store: CourseStore) {
        self.store = store
        reloadMarks()
    }

    var currentLocale: String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    /// Reads the hidden courses, the user's names and the ignored courses back from the stores.
    func reloadMarks() {
        deletedCourseNos = Set(store.loadDeletedCourseNos())
        courseCustomNames = store.loadCourseCustomNames()
        ignoredAssignmentCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
    }

    /// The user's own table is on screen. A late call once the class table is gone, such as the
    /// colour picker's delayed pick, edits nothing.
    private var isEditable: Bool {
        owner.map { $0.shownPerson == nil } ?? false
    }

    func closeDialogs() {
        dialogs.showAddCourse = false
        dialogs.showResetConfirm = false
        dialogs.showRenameAlert = false
        dialogs.courseToRename = nil
        dialogs.courseToRecolor = nil
    }

    func applyCustomizations(_ courses: inout [CourseStore.Course]) {
        guard let semester = owner?.currentSemester else { return }
        courses.removeAll { CourseStore.Tombstone.isHidden($0.courseNo, semester: semester, in: deletedCourseNos) }
        let locale = currentLocale
        for course in courses {
            course.customName = courseCustomNames[course.courseNo]?[locale]
        }
    }

    @discardableResult
    func addCourse(_ course: CourseStore.Course) -> Bool {
        guard let table = owner, table.shownPerson == nil else { return false }
        let semester = table.currentSemester
        if table.courses.contains(where: { $0.courseNo == course.courseNo }) {
            if store.apply(.unhide(courseNo: course.courseNo, semester: semester)) {
                deletedCourseNos = Set(store.loadDeletedCourseNos())
                sync.courseAdded?(table.courses, semester, course.courseNo)
            }
            return false
        }

        if let err = table.grid.tripleConflict(adding: course) {
            dialogs.tripleConflictError = err
            return false
        }

        if store.apply(.unhide(courseNo: course.courseNo, semester: semester)) {
            deletedCourseNos = Set(store.loadDeletedCourseNos())
            if let idnumber = course.moodleIdNumber,
               let numericId = CourseLookup.moodleCourseId(idnumber: idnumber) {
                sync.courseOverride?(String(numericId), nil, nil, nil)
            }
        }

        NameAbbrService.shared.storeRawName(courseNo: course.courseNo, name: course.courseName)
        NameAbbrService.shared.storeRawClassroom(
            courseNo: course.courseNo, classroom: course.classroom, map: course.classroomMap
        )
        NameAbbrService.shared.relabelInPlace(
            [course],
            courseAbbrEnabled: Defaults[.useEnglishCourseAbbreviation],
            classroomAbbrEnabled: Defaults[.useEnglishClassroomAbbreviation],
            classroomMandarinDisplay: Defaults[.classroomMandarinDisplay]
        )

        course.customName = courseCustomNames[course.courseNo]?[currentLocale]

        table.courses.append(course)
        store.apply(.add(course, semester: semester))
        if sync.courseAdded != nil {
            sync.courseAdded?(table.courses, semester, course.courseNo)
        } else {
            sync.coursesChanged?(table.courses, semester)
        }
        return true
    }

    func deleteCourse(_ course: CourseStore.Course) {
        guard let table = owner, table.shownPerson == nil else { return }
        let courseNo = course.courseNo
        let semester = table.currentSemester
        table.courses.removeAll { $0.courseNo == courseNo }
        store.apply(.delete(courseNo: courseNo, semester: semester))
        deletedCourseNos = Set(store.loadDeletedCourseNos())
        if ignoresAssignments(of: courseNo) {
            AssignmentStore.shared.apply(.ignoreCourse(courseNo: courseNo, semester: semester, ignored: false))
            ignoredAssignmentCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        }
        sync.courseDeleted?(courseNo, semester)
        sync.coursesChanged?(table.courses, semester)
    }

    /// The task keeps the view model alive until the term is reset here too, so leaving the
    /// class table while the backend delete runs still finishes the reset.
    func resetCourses(authService: AuthService) {
        guard let table = owner, table.shownPerson == nil else { return }
        let semester = table.currentSemester
        guard !resettingSemesters.contains(semester) else { return }
        resettingSemesters.insert(semester)
        Task {
            defer { self.resettingSemesters.remove(semester) }
            let resetLocally: @MainActor () -> Void = { self.resetLocalCourses(of: table, semester: semester) }
            let backendOk: Bool
            if let reset = sync.resetBackendCourses {
                backendOk = await reset(semester, resetLocally)
            } else {
                resetLocally()
                backendOk = true
            }
            guard backendOk else {
                self.dialogs.showResetFailedAlert = true
                return
            }
            while table.loader.isRefreshing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            table.loader.triggerRefresh(authService: authService, semester: semester)
        }
    }

    private func resetLocalCourses(of table: ClassTableViewModel, semester: String) {
        store.apply(.resetTerm(semester))
        AssignmentStore.shared.clearIgnoredAssignmentCourses(semester: semester)
        table.reloadFromCache()
    }

    func removeUserAddedCourse(courseNo: String) {
        guard let table = owner, table.shownPerson == nil,
              let course = table.courses.first(where: { $0.courseNo == courseNo }),
              course.moodleIdNumber == nil
        else { return }
        table.courses.removeAll { $0.courseNo == courseNo }
        store.apply(.remove(courseNo: courseNo, semester: table.currentSemester))
        sync.courseDeleted?(courseNo, table.currentSemester)
    }

    func startRename(_ course: CourseStore.Course) {
        guard isEditable else { return }
        dialogs.courseToRename = course
        dialogs.renameText = course.displayName
        dialogs.showRenameAlert = true
    }

    func confirmRename() {
        guard isEditable, let course = dialogs.courseToRename else { return }
        let trimmed = dialogs.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == course.courseName {
            revertRename(course)
            return
        }
        rename(course, to: trimmed)
    }

    func revertRename(_ course: CourseStore.Course) {
        guard isEditable, dialogs.courseToRename === course else { return }
        rename(course, to: nil)
    }

    private func rename(_ course: CourseStore.Course, to name: String?) {
        let locale = currentLocale
        courseCustomNames[course.courseNo, default: [:]][locale] = name
        if courseCustomNames[course.courseNo]?.isEmpty == true {
            courseCustomNames.removeValue(forKey: course.courseNo)
        }
        store.apply(.rename(courseNo: course.courseNo, name: name, locale: locale))
        course.customName = name
        owner?.grid.rebuildLookup()
        dialogs.courseToRename = nil
        if let moodleId = course.moodleIdNumber {
            sync.courseOverride?(moodleId, nil, name ?? "", locale)
        }
    }

    func startRecolor(_ course: CourseStore.Course) {
        guard isEditable else { return }
        dialogs.courseToRecolor = course
    }

    func ignoresAssignments(of courseNo: String) -> Bool {
        guard let table = owner, table.shownPerson == nil else { return false }
        return ignoredAssignmentCourses.contains(
            CourseStore.Tombstone.key(semester: table.currentSemester, courseNo: courseNo)
        )
    }

    var offersIgnoreAssignments: Bool {
        guard let table = owner else { return false }
        return table.shownPerson == nil && table.currentSemester == SchoolTerms.current
    }

    func setIgnoresAssignments(_ ignore: Bool, for course: CourseStore.Course) {
        guard let table = owner, offersIgnoreAssignments else { return }
        let semester = table.currentSemester
        AssignmentStore.shared.apply(.ignoreCourse(courseNo: course.courseNo, semester: semester, ignored: ignore))
        ignoredAssignmentCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        table.assignments = AssignmentStore.shared.loadAssignments()
        sync.courseIgnore?(course, semester, ignore)
    }

    func setColor(hex: UInt32, for course: CourseStore.Course) {
        guard isEditable else { return }
        let changed = TigerDuckTheme.setColor(hex: hex, for: course.courseNo)
        sync.colorPick?(hex, course, changed)
    }
}

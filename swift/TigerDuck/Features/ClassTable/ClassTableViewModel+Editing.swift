import Defaults
import SwiftUI

extension ClassTableViewModel {

    @discardableResult
    func addCourse(_ course: SDCourse) -> Bool {
        guard shownPerson == nil else { return false }
        let store = courseStore
        if courses.contains(where: { $0.courseNo == course.courseNo }) {
            if store.apply(.unhide(courseNo: course.courseNo, semester: currentSemester)) {
                deletedCourseNos = Set(store.loadDeletedCourseNos())
                onCourseAdded?(courses, currentSemester, course.courseNo)
            }
            return false
        }

        if let err = wouldCauseTripleConflict(course) {
            tripleConflictError = err
            return false
        }

        if store.apply(.unhide(courseNo: course.courseNo, semester: currentSemester)) {
            deletedCourseNos = Set(store.loadDeletedCourseNos())
            if let idnumber = course.moodleIdNumber,
               let numericId = MoodleFiles.shared.lookupMoodleCourseId(idnumber: idnumber) {
                onSyncCourseOverride?(String(numericId), nil, nil, nil)
            }
        }

        NameAbbrService.shared.storeRawName(
            courseNo: course.courseNo, name: course.courseName
        )
        NameAbbrService.shared.storeRawClassroom(
            courseNo: course.courseNo,
            classroom: course.classroom,
            map: course.classroomMap
        )

        NameAbbrService.shared.relabelInPlace(
            [course],
            courseAbbrEnabled: Defaults[.useEnglishCourseAbbreviation],
            classroomAbbrEnabled: Defaults[.useEnglishClassroomAbbreviation],
            classroomMandarinDisplay: Defaults[.classroomMandarinDisplay]
        )

        course.customName = courseCustomNames[course.courseNo]?[currentLocale]

        courses.append(course)
        store.apply(.add(course, semester: currentSemester))
        if onCourseAdded != nil {
            onCourseAdded?(courses, currentSemester, course.courseNo)
        } else {
            onCoursesChanged?(courses, currentSemester)
        }
        return true
    }

    func applyCustomizations(_ courses: inout [SDCourse]) {
        let semester = currentSemester
        courses.removeAll { CourseTombstone.isHidden($0.courseNo, semester: semester, in: deletedCourseNos) }
        let locale = currentLocale
        for course in courses {
            course.customName = courseCustomNames[course.courseNo]?[locale]
        }
    }

    func deleteCourse(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        let courseNo = course.courseNo
        courses.removeAll { $0.courseNo == courseNo }
        courseStore.apply(.delete(courseNo: courseNo, semester: currentSemester))
        deletedCourseNos = Set(courseStore.loadDeletedCourseNos())
        if ignoresAssignments(of: courseNo) {
            AssignmentStore.shared.apply(.ignoreCourse(courseNo: courseNo, semester: currentSemester, ignored: false))
            ignoredAssignmentCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        }
        onCourseDeleted?(courseNo, currentSemester)
        onCoursesChanged?(courses, currentSemester)
    }

    func resetCourses(authService: AuthService) {
        guard shownPerson == nil else { return }
        let semester = currentSemester
        guard !resettingSemesters.contains(semester) else { return }
        resettingSemesters.insert(semester)
        Task { [weak self] in
            guard let self else { return }
            defer { self.resettingSemesters.remove(semester) }
            let resetLocally: @MainActor () -> Void = { self.resetLocalCourses(semester: semester) }
            let backendOk: Bool
            if let onResetBackendCourses {
                backendOk = await onResetBackendCourses(semester, resetLocally)
            } else {
                resetLocally()
                backendOk = true
            }
            guard backendOk else {
                self.showResetFailedAlert = true
                return
            }
            while self.isRefreshing {
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.triggerRefresh(authService: authService, semester: semester)
        }
    }

    private func resetLocalCourses(semester: String) {
        courseStore.apply(.resetTerm(semester))
        AssignmentStore.shared.clearIgnoredAssignmentCourses(semester: semester)
        reloadFromCache()
    }

    func removeUserAddedCourse(courseNo: String) {
        guard shownPerson == nil,
              let course = courses.first(where: { $0.courseNo == courseNo }),
              course.moodleIdNumber == nil
        else { return }
        courses.removeAll { $0.courseNo == courseNo }
        courseStore.apply(.remove(courseNo: courseNo, semester: currentSemester))
        onCourseDeleted?(courseNo, currentSemester)
    }

    func startRename(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        courseToRename = course
        renameText = course.displayName
        showRenameAlert = true
    }

    func confirmRename() {
        guard shownPerson == nil, let course = courseToRename else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == course.courseName {
            revertRename(course)
            return
        }
        let locale = currentLocale
        courseCustomNames[course.courseNo, default: [:]][locale] = trimmed
        courseStore.apply(.rename(courseNo: course.courseNo, name: trimmed, locale: locale))
        course.customName = trimmed
        rebuildLookup()
        courseToRename = nil
        syncNameOverride(course: course, customName: trimmed, locale: locale)
    }

    func revertRename(_ course: SDCourse) {
        guard shownPerson == nil, courseToRename === course else { return }
        let locale = currentLocale
        courseCustomNames[course.courseNo]?[locale] = nil
        if courseCustomNames[course.courseNo]?.isEmpty == true {
            courseCustomNames.removeValue(forKey: course.courseNo)
        }
        courseStore.apply(.rename(courseNo: course.courseNo, name: nil, locale: locale))
        course.customName = nil
        rebuildLookup()
        courseToRename = nil
        syncNameOverride(course: course, customName: "", locale: locale)
    }

    func startRecolor(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        courseToRecolor = course
    }

    func setIgnoresAssignments(_ ignore: Bool, for course: SDCourse) {
        guard offersIgnoreAssignments else { return }
        let semester = currentSemester
        AssignmentStore.shared.apply(.ignoreCourse(courseNo: course.courseNo, semester: semester, ignored: ignore))
        ignoredAssignmentCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        assignments = AssignmentStore.shared.loadAssignments()
        onSyncCourseIgnore?(course, semester, ignore)
    }

    func setColor(hex: UInt32, for course: SDCourse) {
        guard shownPerson == nil else { return }
        let changed = TigerDuckTheme.setColor(hex: hex, for: course.courseNo)
        onSyncColorPick?(hex, course, changed)
    }

    private func syncNameOverride(course: SDCourse, customName: String, locale: String) {
        guard let moodleId = course.moodleIdNumber else { return }
        onSyncCourseOverride?(moodleId, nil, customName, locale)
    }
}

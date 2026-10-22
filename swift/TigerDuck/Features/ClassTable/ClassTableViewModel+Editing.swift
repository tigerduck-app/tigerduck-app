import Defaults
import SwiftUI

extension ClassTableViewModel {

    @discardableResult
    func addCourse(_ course: SDCourse) -> Bool {
        guard shownPerson == nil else { return false }
        if courses.contains(where: { $0.courseNo == course.courseNo }) {
            if CourseTombstone.unhide(course.courseNo, semester: currentSemester, from: &deletedCourseNos) {
                DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
                onCourseAdded?(courses, currentSemester, course.courseNo)
            }
            return false
        }

        if let err = wouldCauseTripleConflict(course) {
            tripleConflictError = err
            return false
        }

        if CourseTombstone.unhide(course.courseNo, semester: currentSemester, from: &deletedCourseNos) {
            DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
            if let idnumber = course.moodleIdNumber,
               let numericId = DataCache.shared.lookupMoodleCourseId(idnumber: idnumber) {
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
        persistUserAddedCourses()
        broadcastLocalChange()
        if onCourseAdded != nil {
            onCourseAdded?(courses, currentSemester, course.courseNo)
        } else {
            onCoursesChanged?(courses, currentSemester)
        }
        return true
    }

    private func persistUserAddedCourses() {
        guard shownPerson == nil else { return }
        let mine = courses.filter { $0.moodleIdNumber == nil }
        for course in mine where course.semester.isEmpty {
            course.semester = currentSemester
        }
        let survivingNos = Set(mine.map(\.courseNo))
        let others = DataCache.shared.loadUserAddedCourses().filter { stored in
            if stored.semester == currentSemester { return false }
            if stored.semester.isEmpty { return !survivingNos.contains(stored.courseNo) }
            return true
        }
        DataCache.shared.saveUserAddedCourses(others + mine)
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
        deletedCourseNos.insert(CourseTombstone.key(semester: currentSemester, courseNo: courseNo))
        DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
        if ignoresAssignments(of: courseNo) {
            DataCache.shared.setAssignmentsIgnored(false, semester: currentSemester, courseNo: courseNo)
            ignoredAssignmentCourses = DataCache.shared.loadIgnoredAssignmentCourses()
        }
        persistUserAddedCourses()
        broadcastLocalChange()
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
        deletedCourseNos.subtract(CourseTombstone.entries(resetting: semester, in: deletedCourseNos))
        DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
        DataCache.shared.saveUserAddedCourses(
            DataCache.shared.loadUserAddedCourses().filter { !DataCache.userAddedCourse($0, belongsTo: semester) }
        )
        for courseNo in DataCache.shared.loadCourses(semester: semester).map(\.courseNo) {
            courseCustomNames.removeValue(forKey: courseNo)
        }
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        DataCache.shared.clearIgnoredAssignmentCourses(semester: semester)
        DataCache.shared.clearCourses(semester: semester)
        reloadFromCache()
    }

    func removeUserAddedCourse(courseNo: String) {
        guard shownPerson == nil,
              let course = courses.first(where: { $0.courseNo == courseNo }),
              course.moodleIdNumber == nil
        else { return }
        courses.removeAll { $0.courseNo == courseNo }
        persistUserAddedCourses()
        broadcastLocalChange()
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
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        course.customName = trimmed
        rebuildLookup()
        persistUserAddedCourses()
        courseToRename = nil
        broadcastLocalChange()
        syncNameOverride(course: course, customName: trimmed, locale: locale)
    }

    func revertRename(_ course: SDCourse) {
        guard shownPerson == nil, courseToRename === course else { return }
        let locale = currentLocale
        courseCustomNames[course.courseNo]?[locale] = nil
        if courseCustomNames[course.courseNo]?.isEmpty == true {
            courseCustomNames.removeValue(forKey: course.courseNo)
        }
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        course.customName = nil
        rebuildLookup()
        persistUserAddedCourses()
        courseToRename = nil
        broadcastLocalChange()
        syncNameOverride(course: course, customName: "", locale: locale)
    }

    func startRecolor(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        courseToRecolor = course
    }

    func setIgnoresAssignments(_ ignore: Bool, for course: SDCourse) {
        guard offersIgnoreAssignments else { return }
        let semester = currentSemester
        DataCache.shared.setAssignmentsIgnored(ignore, semester: semester, courseNo: course.courseNo)
        ignoredAssignmentCourses = DataCache.shared.loadIgnoredAssignmentCourses()
        assignments = DataCache.shared.loadAssignments()
        broadcastLocalChange()
        onSyncCourseIgnore?(course, semester, ignore)
    }

    func setColor(hex: UInt32, for course: SDCourse) {
        guard shownPerson == nil else { return }
        let changed = TigerDuckTheme.setColor(hex: hex, for: course.courseNo)
        broadcastLocalChange()
        onSyncColorPick?(hex, course, changed)
    }

    private func syncNameOverride(course: SDCourse, customName: String, locale: String) {
        guard let moodleId = course.moodleIdNumber else { return }
        onSyncCourseOverride?(moodleId, nil, customName, locale)
    }
}

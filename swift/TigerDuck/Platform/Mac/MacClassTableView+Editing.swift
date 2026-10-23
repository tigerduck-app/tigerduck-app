#if os(macOS)
import SwiftUI
import Defaults

extension MacClassTableView {

    @discardableResult
    func addUserCourse(_ course: SDCourse) -> Bool {
        guard shownPerson == nil else { return false }
        let existing = DataCache.shared.loadUserAddedCourses()
        let isInSelectedSemester: (SDCourse) -> Bool = {
            $0.semester == selectedSemester || $0.semester.isEmpty
        }
        guard !existing.contains(where: { $0.courseNo == course.courseNo && isInSelectedSemester($0) }),
              !courses.contains(where: { $0.courseNo == course.courseNo })
        else { return false }

        if let err = firstTripleConflict(for: course) {
            tripleConflictError = err
            return false
        }

        var deleted = Set(DataCache.shared.loadDeletedCourseNos())
        if CourseTombstone.unhide(course.courseNo, semester: selectedSemester, from: &deleted) {
            DataCache.shared.saveDeletedCourseNos(Array(deleted))
        }

        NameAbbrService.shared.storeRawName(
            courseNo: course.courseNo, name: course.courseName
        )
        NameAbbrService.shared.storeRawClassroom(
            courseNo: course.courseNo,
            classroom: course.classroom,
            map: course.classroomMap
        )

        DataCache.shared.saveUserAddedCourses(existing + [course])
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        let forceKey = CourseTombstone.serverKey(semester: selectedSemester, courseNo: course.courseNo)
        appState.uploadCourses(courses, semester: selectedSemester, forceKeys: [forceKey])
        return true
    }

    private func firstTripleConflict(for candidate: SDCourse) -> TripleConflictError? {
        for (weekday, periodIds) in candidate.schedule {
            for pid in periodIds {
                let occupants = courses.filter {
                    ($0.schedule[weekday] ?? []).contains(pid)
                }
                if occupants.count >= 2 {
                    return TripleConflictError(
                        weekday: weekday,
                        periodId: pid,
                        newCourseName: candidate.displayName,
                        existingA: occupants[0],
                        existingB: occupants[1]
                    )
                }
            }
        }
        return nil
    }

    func removeUserAddedCourse(courseNo: String) {
        guard shownPerson == nil else { return }
        let existing = DataCache.shared.loadUserAddedCourses()
        let updated = existing.filter { course in
            !(course.courseNo == courseNo && (course.semester == selectedSemester || course.semester.isEmpty))
        }
        guard updated.count != existing.count else { return }
        DataCache.shared.saveUserAddedCourses(updated)
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        appState.deleteBackendCourse(courseNo: courseNo, semester: selectedSemester)
    }

    func startRename(_ course: SDCourse) {
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
        let locale = LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
        var names = DataCache.shared.loadCourseCustomNames()
        names[course.courseNo, default: [:]][locale] = trimmed
        DataCache.shared.saveCourseCustomNames(names)
        courseToRename = nil
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        if let moodleId = course.moodleIdNumber {
            appState.syncCourseOverride(moodleCourseId: moodleId, customName: trimmed, locale: locale)
        }
    }

    func revertRename(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        let locale = LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
        var names = DataCache.shared.loadCourseCustomNames()
        names[course.courseNo]?[locale] = nil
        if names[course.courseNo]?.isEmpty == true {
            names.removeValue(forKey: course.courseNo)
        }
        DataCache.shared.saveCourseCustomNames(names)
        courseToRename = nil
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        if let moodleId = course.moodleIdNumber {
            appState.syncCourseOverride(moodleCourseId: moodleId, customName: "", locale: locale)
        }
    }

    func setIgnoresAssignments(_ ignore: Bool, for course: SDCourse) {
        guard shownPerson == nil, isViewingCurrentSemester else { return }
        DataCache.shared.setAssignmentsIgnored(ignore, semester: selectedSemester, courseNo: course.courseNo)
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        appState.syncCourseIgnore(
            semester: selectedSemester, courseNo: course.courseNo, moodleIdNumber: course.moodleIdNumber, ignore: ignore
        )
    }

    func deleteCourse(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        var deleted = Set(DataCache.shared.loadDeletedCourseNos())
        deleted.insert(CourseTombstone.key(semester: selectedSemester, courseNo: course.courseNo))
        DataCache.shared.saveDeletedCourseNos(Array(deleted))
        if ignoredAssignmentCourses.contains(CourseTombstone.key(semester: selectedSemester, courseNo: course.courseNo)) {
            DataCache.shared.setAssignmentsIgnored(false, semester: selectedSemester, courseNo: course.courseNo)
        }

        let existing = DataCache.shared.loadUserAddedCourses()
        let pruned = existing.filter { entry in
            !(entry.courseNo == course.courseNo && (entry.semester == selectedSemester || entry.semester.isEmpty))
        }
        if pruned.count != existing.count {
            DataCache.shared.saveUserAddedCourses(pruned)
        }

        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        appState.deleteBackendCourse(courseNo: course.courseNo, semester: selectedSemester)
        appState.uploadCourses(courses.filter { $0.courseNo != course.courseNo }, semester: selectedSemester)
    }
}
#endif

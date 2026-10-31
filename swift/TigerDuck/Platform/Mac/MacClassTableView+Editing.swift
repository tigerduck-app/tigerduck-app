#if os(macOS)
import SwiftUI
import Defaults

extension MacClassTableView {

    @discardableResult
    func addUserCourse(_ course: SDCourse) -> Bool {
        guard shownPerson == nil else { return false }
        let existing = CourseStore.shared.loadUserAddedCourses()
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

        CourseStore.shared.apply(.unhide(courseNo: course.courseNo, semester: selectedSemester))

        NameAbbrService.shared.storeRawName(
            courseNo: course.courseNo, name: course.courseName
        )
        NameAbbrService.shared.storeRawClassroom(
            courseNo: course.courseNo,
            classroom: course.classroom,
            map: course.classroomMap
        )

        CourseStore.shared.apply(.add(course, semester: selectedSemester))
        cacheRevision &+= 1
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
        guard CourseStore.shared.apply(.remove(courseNo: courseNo, semester: selectedSemester)) else { return }
        cacheRevision &+= 1
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
        CourseStore.shared.apply(.rename(courseNo: course.courseNo, name: trimmed, locale: locale))
        courseToRename = nil
        cacheRevision &+= 1
        if let moodleId = course.moodleIdNumber {
            appState.syncCourseOverride(moodleCourseId: moodleId, customName: trimmed, locale: locale)
        }
    }

    func revertRename(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        let locale = LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
        CourseStore.shared.apply(.rename(courseNo: course.courseNo, name: nil, locale: locale))
        courseToRename = nil
        cacheRevision &+= 1
        if let moodleId = course.moodleIdNumber {
            appState.syncCourseOverride(moodleCourseId: moodleId, customName: "", locale: locale)
        }
    }

    func setIgnoresAssignments(_ ignore: Bool, for course: SDCourse) {
        guard shownPerson == nil, isViewingCurrentSemester else { return }
        AssignmentStore.shared.apply(.ignoreCourse(courseNo: course.courseNo, semester: selectedSemester, ignored: ignore))
        cacheRevision &+= 1
        appState.syncCourseIgnore(
            semester: selectedSemester, courseNo: course.courseNo, moodleIdNumber: course.moodleIdNumber, ignore: ignore
        )
    }

    func deleteCourse(_ course: SDCourse) {
        guard shownPerson == nil else { return }
        CourseStore.shared.apply(.delete(courseNo: course.courseNo, semester: selectedSemester))
        if ignoredAssignmentCourses.contains(CourseTombstone.key(semester: selectedSemester, courseNo: course.courseNo)) {
            AssignmentStore.shared.apply(.ignoreCourse(courseNo: course.courseNo, semester: selectedSemester, ignored: false))
        }

        cacheRevision &+= 1
        appState.deleteBackendCourse(courseNo: course.courseNo, semester: selectedSemester)
        appState.uploadCourses(courses.filter { $0.courseNo != course.courseNo }, semester: selectedSemester)
    }
}
#endif

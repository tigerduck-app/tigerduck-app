import SwiftUI
import Defaults
import TigerDuckCore

extension AppState {

    func relabelAllCachedCourses() {
        relabelTask?.cancel()
        relabelTask = Task.detached(priority: .userInitiated) {
            let courseAbbrEnabled = Defaults[.useEnglishCourseAbbreviation]
            let classroomAbbrEnabled = Defaults[.useEnglishClassroomAbbreviation]
            let classroomMandarinDisplay = Defaults[.classroomMandarinDisplay]

            var anyChanged = false
            var code = CourseSelectionService.currentSemesterCode()
            var consecutiveEmpty = 0
            for _ in 0..<AppConstants.cachedSemesterRelabelDepth {
                if Task.isCancelled { return }
                let semesterCode = code
                let iter = await MainActor.run { () -> (changed: Bool, wasEmpty: Bool) in
                    let courses = DataCache.shared.loadCourses(semester: semesterCode)
                    if courses.isEmpty { return (false, true) }
                    let changed = NameAbbrService.shared.relabelInPlace(
                        courses,
                        courseAbbrEnabled: courseAbbrEnabled,
                        classroomAbbrEnabled: classroomAbbrEnabled,
                        classroomMandarinDisplay: classroomMandarinDisplay
                    )
                    if changed && !Task.isCancelled {
                        DataCache.shared.saveCourses(courses, semester: semesterCode)
                    }
                    return (changed, false)
                }
                if iter.wasEmpty {
                    consecutiveEmpty += 1
                    if consecutiveEmpty >= 2 { break }
                } else {
                    consecutiveEmpty = 0
                }
                if iter.changed { anyChanged = true }
                code = AcademicTerm.previousRegularCode(code)
            }

            if Task.isCancelled { return }
            let userChanged = await MainActor.run { () -> Bool in
                let userAdded = DataCache.shared.loadUserAddedCourses()
                guard !userAdded.isEmpty else { return false }
                let changed = NameAbbrService.shared.relabelInPlace(
                    userAdded,
                    courseAbbrEnabled: courseAbbrEnabled,
                    classroomAbbrEnabled: classroomAbbrEnabled,
                    classroomMandarinDisplay: classroomMandarinDisplay
                )
                if changed && !Task.isCancelled {
                    DataCache.shared.saveUserAddedCourses(userAdded)
                }
                return changed
            }
            if userChanged { anyChanged = true }

            if anyChanged && !Task.isCancelled {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: AppConstants.dataDidUpdate, object: nil
                    )
                }
            }
        }
    }

}

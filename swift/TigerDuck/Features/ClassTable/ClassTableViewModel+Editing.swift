// User edits to the class table: adding, deleting, renaming and recolouring
// courses, plus the writes that make them survive a refresh. Every path must
// persist locally and tell the backend, so the sync hooks run here, not in views.

import Defaults
import SwiftUI

extension ClassTableViewModel {

    /// AddCourseSheet uses this signal to gate its session checkmark so
    /// a rejected add (duplicate, triple-period conflict) can't trick
    /// the next tap into routing through `removeUserAddedCourse`.
    @discardableResult
    func addCourse(_ course: SDCourse) -> Bool {
        // A course both tombstoned and in `courses` (a refresh re-fetched it past
        // a stale tombstone) is un-hidden before returning, so later reloads stop
        // filtering it. Returns `false`: the row was already in the timetable.
        if courses.contains(where: { $0.courseNo == course.courseNo }) {
            if CourseTombstone.unhide(course.courseNo, semester: currentSemester, from: &deletedCourseNos) {
                DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
            }
            return false
        }

        // Refuse when a slot it needs already holds 2 courses: three have no
        // sensible rendering (Android also caps at 2). Check before clearing the
        // tombstone, or a rejected add un-hides the course on the next reload.
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

        // Cache the freshly-fetched API values BEFORE any local mutation so
        // abbreviation toggles can round-trip without a network refetch
        // (mirrors AppServiceBridge.fetchCourses).
        NameAbbrService.shared.storeRawName(
            courseNo: course.courseNo, name: course.courseName
        )
        NameAbbrService.shared.storeRawClassroom(
            courseNo: course.courseNo,
            classroom: course.classroom,
            map: course.classroomMap
        )

        // Apply current display toggles immediately so a newly-added course
        // with a Mandarin classroom shows in the user's chosen form (pinyin /
        // translated / original) without requiring them to flip the toggle.
        NameAbbrService.shared.relabelInPlace(
            [course],
            courseAbbrEnabled: Defaults[.useEnglishCourseAbbreviation],
            classroomAbbrEnabled: Defaults[.useEnglishClassroomAbbreviation],
            classroomMandarinDisplay: Defaults[.classroomMandarinDisplay]
        )

        // Reapply a persisted custom name, as after a remove and re-add. It is kept
        // apart from `courseName` so abbreviation toggles and refreshes still run
        // the API value through `NameAbbrService`.
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

    /// Replaces only `currentSemester`'s slice of the user-added store.
    ///
    /// `courses` holds one semester, so writing it wholesale — which this
    /// used to do — drops every other semester's manual additions the moment
    /// the user adds or removes one here. That stayed invisible while the
    /// merge surfaced all semesters' rows in every timetable; scoping the
    /// merge is what makes the wholesale write destructive.
    private func persistUserAddedCourses() {
        let mine = courses.filter { $0.moodleIdNumber == nil }
        // Stamp rows that predate per-semester tracking with the semester
        // they are being shown in, so they stop leaking into all of them.
        for course in mine where course.semester.isEmpty {
            course.semester = currentSemester
        }
        // A row stamped for this term is always replaced; that is how a delete removes
        // it. An unstamped row is replaced only if in `mine`: `mergeWithUserAdded` hides
        // one whose courseNo a fetched course owns, and with no term nothing restores it.
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
        let courseNo = course.courseNo
        courses.removeAll { $0.courseNo == courseNo }
        deletedCourseNos.insert(CourseTombstone.key(semester: currentSemester, courseNo: courseNo))
        DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
        persistUserAddedCourses()
        broadcastLocalChange()
        onCourseDeleted?(courseNo, currentSemester)
        onCoursesChanged?(courses, currentSemester)
    }

    /// Rebuilds only the term the picker is on: its hidden courses
    /// resurface, its manual additions and custom names go, the backend
    /// drops that term, and a forced refetch repopulates it from Moodle,
    /// the course-selection system and the grade report. Other terms are
    /// untouched.
    func resetCourses(authService: AuthService) {
        let semester = currentSemester
        // One at a time per term: two refetches racing each other's
        // uploads is nothing anyone needs.
        guard !resettingSemesters.contains(semester) else { return }
        resettingSemesters.insert(semester)
        Task { [weak self] in
            guard let self else { return }
            defer { self.resettingSemesters.remove(semester) }
            // Backend first. `AppState.deleteBackendCourses` runs the local wipe on
            // success only, latches the term against the revision poll across both,
            // and stamps the reset; offline or unauthorised, nothing is touched.
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
            // Then refetch; its upload releases this device's reset tombstones. Use
            // the captured term, not the picker's current one, and wait out any
            // running pull-to-refresh, as the two would race on cache writes.
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
        // ponytail: custom names are keyed by course number only, so a
        // retaken course loses its alias in the other term as well.
        for courseNo in DataCache.shared.loadCourses(semester: semester).map(\.courseNo) {
            courseCustomNames.removeValue(forKey: courseNo)
        }
        DataCache.shared.saveCourseCustomNames(courseCustomNames)
        // Clear the portal cache too, in every language: a reset starts the term over.
        // An old roster left beside an empty server term would go back up on a poll,
        // and this device's upload releases its reset tombstones, undoing the reset.
        DataCache.shared.clearCourses(semester: semester)
        reloadFromCache()
    }

    /// Undo a just-added user course without tombstoning its `courseNo`, for
    /// AddCourseSheet's tap-to-toggle: add a course, tap again to back out. A
    /// tombstone in `deletedCourseNos` would later hide a real enrolled course
    /// with the same `courseNo` from cache and network merges (see `applyCustomizations`).
    ///
    /// Only removes user-added courses (`moodleIdNumber == nil`); a stray call for
    /// a real enrolled course is a no-op, so enrolled courses leave only through
    /// the regular drop and hide flow.
    func removeUserAddedCourse(courseNo: String) {
        guard let course = courses.first(where: { $0.courseNo == courseNo }),
              course.moodleIdNumber == nil
        else { return }
        courses.removeAll { $0.courseNo == courseNo }
        persistUserAddedCourses()
        broadcastLocalChange()
        // The add already uploaded the row, so delete it server-side or the next full
        // sync brings it back. ponytail: the POST and this DELETE are independent tasks,
        // so a tap-tap within one round trip can leave the row; a reset clears it.
        onCourseDeleted?(courseNo, currentSemester)
    }

    func startRename(_ course: SDCourse) {
        courseToRename = course
        renameText = course.displayName
        showRenameAlert = true
    }

    func confirmRename() {
        guard let course = courseToRename else { return }
        // Trim whitespace *and* newlines so a pasted "\nDefault\n" still
        // collapses to empty and routes through the revert path instead of
        // saving an invisible/line-breaking alias.
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty (or unchanged-from-default) means the user wants to revert to
        // the canonical name. Clearing the override is also what the explicit
        // "Revert to default" button does.
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
        let locale = currentLocale
        courseCustomNames[course.courseNo]?[locale] = nil
        // Remove the outer entry entirely when no locale overrides remain
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
        courseToRecolor = course
    }

    /// Apply a picked color, preset or custom. Writes through `TigerDuckTheme`,
    /// which moves any other course off the same hex so no two courses share a color,
    /// then broadcasts so Home, Class Table, widgets and the Live Activity refresh.
    ///
    /// Leaves `courseToRecolor` set: the ColorPicker sends `onSelect` ticks
    /// throughout a drag, and dismissing here would close the sheet on the first.
    /// `CourseColorPickerSheet` calls `dismiss()` itself on a preset tap or Close.
    func setColor(hex: UInt32, for course: SDCourse) {
        TigerDuckTheme.setColor(hex: hex, for: course.courseNo)
        broadcastLocalChange()
        syncColorOverride(course: course, hex: hex)
    }

    private func syncColorOverride(course: SDCourse, hex: UInt32) {
        guard let moodleId = course.moodleIdNumber else { return }
        let hexStr = String(format: "#%06X", hex)
        onSyncCourseOverride?(moodleId, hexStr, nil, nil)
    }

    private func syncNameOverride(course: SDCourse, customName: String, locale: String) {
        guard let moodleId = course.moodleIdNumber else { return }
        onSyncCourseOverride?(moodleId, nil, customName, locale)
    }
}

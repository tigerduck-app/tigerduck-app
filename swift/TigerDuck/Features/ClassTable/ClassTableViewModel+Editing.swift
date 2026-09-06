// User edits to the class table — split out of ClassTableViewModel.swift.
//
// Adding, deleting, renaming and recolouring courses, plus the writes
// that make those survive a refresh. Every path here has to both persist
// locally and tell the backend, which is why the sync hooks are called
// from here rather than from the views.

import Defaults
import SwiftUI

extension ClassTableViewModel {

    /// AddCourseSheet uses this signal to gate its session checkmark so
    /// a rejected add (duplicate, triple-period conflict) can't trick
    /// the next tap into routing through `removeUserAddedCourse`.
    @discardableResult
    func addCourse(_ course: SDCourse) -> Bool {
        // Self-heal the inconsistent state where a course is BOTH tombstoned
        // and currently present in `courses` (e.g. a refresh re-fetched it
        // while a stale tombstone lingered). Done before the early-return so
        // future reloads stop filtering it. Reports `false` since nothing
        // was newly appended — the row was already in the timetable.
        if courses.contains(where: { $0.courseNo == course.courseNo }) {
            if CourseTombstone.unhide(course.courseNo, semester: currentSemester, from: &deletedCourseNos) {
                DataCache.shared.saveDeletedCourseNos(Array(deletedCourseNos))
            }
            return false
        }

        // Refuse if any slot it occupies already has 2 courses — three
        // concurrent courses don't have a sensible rendering (Android caps
        // at 2 with a warning; we surface an alert instead). Must come
        // BEFORE we clear the tombstone, otherwise a rejected add leaves
        // the tombstone cleared and the next reload resurrects the course.
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

        // Apply the custom-name overlay if one persists for this course
        // (e.g. user removed and re-added). Stored separately from the
        // canonical courseName so abbreviation toggles and refreshes still
        // round-trip the API value through `NameAbbrService`.
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
        // Keep everything `mine` does not stand in for. An unstamped row is
        // only replaced when it actually surfaced here — `mergeWithUserAdded`
        // drops a manual row whose courseNo a fetched course already owns, so
        // matching it on semester alone would erase it from the store, and
        // with no semester recorded there is no other slice it could return
        // in. A row stamped for this semester is replaced unconditionally:
        // that is how a delete removes it.
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
        Task { [weak self] in
            guard let self else { return }
            // Wipe the backend BEFORE touching local state or refetching: the
            // refetch auto-uploads the fresh roster, so a delete landing after
            // it would erase it again — and a delete that never landed would
            // let the next sync merge the stale server rows straight back.
            // Offline or unauthorised, nothing is reset and the user is told.
            guard await self.onResetBackendCourses?(semester) ?? true else {
                self.showResetFailedAlert = true
                return
            }
            self.resetLocalCourses(semester: semester)
            self.triggerRefresh(authService: authService)
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
        reloadFromCache()
    }

    /// Undo a not-yet-committed user-added course without tombstoning the
    /// `courseNo`. Used by AddCourseSheet's tap-to-toggle path so the user
    /// can add a course, then immediately tap it again to back out, without
    /// poisoning `deletedCourseNos` — which would later hide any real
    /// enrolled course sharing the same `courseNo` from cache/network merges
    /// (see `applyCustomizations`).
    ///
    /// Defensive: only removes courses that came from the user-added cache
    /// (`moodleIdNumber == nil`). A stray call against a real enrolled course
    /// is a no-op, so callers can route through this without risking the
    /// regular drop/hide flow.
    func removeUserAddedCourse(courseNo: String) {
        guard let course = courses.first(where: { $0.courseNo == courseNo }),
              course.moodleIdNumber == nil
        else { return }
        courses.removeAll { $0.courseNo == courseNo }
        persistUserAddedCourses()
        broadcastLocalChange()
        // The add already uploaded the row; drop it server-side too or the
        // next full sync brings the course back. ponytail: the add's POST and
        // this DELETE are independent tasks, so a tap-tap faster than one
        // round trip can still leave the row; a reset clears it.
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

    /// Apply a user-picked color (preset or fully custom) for this course.
    /// Writes through TigerDuckTheme — which also displaces any other course
    /// currently holding the same hex so the "no two courses share a color"
    /// invariant survives the edit — then broadcasts so Home, Class Table,
    /// widgets and the Live Activity all refresh.
    ///
    /// Intentionally does *not* clear `courseToRecolor`: the ColorPicker
    /// emits a continuous stream of `onSelect` ticks while the user drags
    /// the slider, so auto-dismissing here would close the sheet after the
    /// first intermediate value and strand the rest of the gesture.
    /// `CourseColorPickerSheet` calls `dismiss()` itself when a preset tap
    /// (or the Close button) actually finishes the picking session.
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

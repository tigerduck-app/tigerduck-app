#if os(macOS)
import SwiftUI
import Defaults

/// Mutations the Mac grid can make to a schedule: add and remove a
/// user-added course, rename one, and delete one.
///
/// Each writes an on-disk store keyed by `courseNo` alone, so call sites gate them on
/// `isViewingCurrentSemester`: a rename made on a past term would otherwise leak into the current
/// schedule, the widgets and the Live Activity for any course reusing the code. iOS runs these
/// through `ClassTableViewModel`; the Mac view has no view-model, so they live on the view.
extension MacClassTableView {
    // MARK: - User-added courses

    /// Append a user-added course to the on-disk store and refresh the grid.
    /// Mirrors the parts of `ClassTableViewModel.addCourse(_:)` macOS relies on: the tombstone
    /// clear, NameAbbr cache seeding so toggles round-trip without a refetch, and a
    /// `dataDidUpdate` broadcast so the Home page's widget cards re-render too.
    /// - Returns: `true` only when the course was newly persisted. AddCourseSheet flips its
    ///   session checkmark on it; flipped after a rejected duplicate, the next tap would call
    ///   `removeUserAddedCourse` and delete the course already added for this semester.
    @discardableResult
    func addUserCourse(_ course: SDCourse) -> Bool {
        let existing = DataCache.shared.loadUserAddedCourses()
        // Dedupe within the selected semester only: a `courseNo` can recur across terms, and
        // `removeUserAddedCourse` scopes its undo to `selectedSemester`. `courses` holds only
        // the current semester's roster, so its check is semester-scoped already.
        let isInSelectedSemester: (SDCourse) -> Bool = {
            $0.semester == selectedSemester || $0.semester.isEmpty
        }
        guard !existing.contains(where: { $0.courseNo == course.courseNo && isInSelectedSemester($0) }),
              !courses.contains(where: { $0.courseNo == course.courseNo })
        else { return false }

        // Refuse a third course in any slot: `ClassTableLayout` can render N-way conflicts, but
        // storing 3+ is a bug surface (Android caps at 2, iPhone rejects too). This runs before
        // the tombstone clear, or a rejected add clears it and the next reload revives the course.
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
        let forceKey = "client:\(selectedSemester):\(course.courseNo)"
        appState.uploadCourses(courses, semester: selectedSemester, forceKeys: [forceKey])
        return true
    }

    /// Scans every slot `candidate` would occupy and returns the first one
    /// that already has two courses — adding the candidate there would push
    /// it to three. Returns nil when the add is safe.
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

    /// Undo a not-yet-committed user-added course without tombstoning the
    /// `courseNo`. Tap-to-toggle in `AddCourseSheet` routes here when the user
    /// adds and immediately removes a course in the same session.
    /// Scoped to the currently-selected semester so undoing `X` here doesn't
    /// also delete a manually-added `X` the user saved for a different
    /// semester (the sheet's onRemove callback only carries the courseNo).
    func removeUserAddedCourse(courseNo: String) {
        let existing = DataCache.shared.loadUserAddedCourses()
        let updated = existing.filter { course in
            !(course.courseNo == courseNo && (course.semester == selectedSemester || course.semester.isEmpty))
        }
        guard updated.count != existing.count else { return }
        DataCache.shared.saveUserAddedCourses(updated)
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        appState.uploadCourses(courses.filter { $0.courseNo != courseNo }, semester: selectedSemester)
    }

    // MARK: - Rename

    /// Right-click "Rename" — opens the rename alert pre-filled with the
    /// course's current display name. Mirrors `ClassTableViewModel.startRename`.
    func startRename(_ course: SDCourse) {
        courseToRename = course
        renameText = course.displayName
        showRenameAlert = true
    }

    /// Commit the typed alias to `DataCache.courseCustomNames`. Empty or
    /// equal-to-canonical input is treated as a revert so the user can clear
    /// the override by typing nothing. Mirrors the iPhone confirmRename rules
    /// 1:1 so renames stay consistent across platforms.
    func confirmRename() {
        guard let course = courseToRename else { return }
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

    /// Clear the alias so `displayName` falls back to the canonical NTUST
    /// course name. Also surfaced as the destructive button in the rename
    /// alert when an override is already set.
    func revertRename(_ course: SDCourse) {
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

    /// Right-click "Delete" — mirrors `ClassTableViewModel.deleteCourse` on
    /// iPhone. Tombstones the courseNo so a future cache refresh from NTUST
    /// can't resurrect a course the user deliberately removed, AND drops any
    /// user-added entry for the courseNo in this semester so the row vanishes
    /// immediately whether the source was an enrolled course or a manual add.
    func deleteCourse(_ course: SDCourse) {
        var deleted = Set(DataCache.shared.loadDeletedCourseNos())
        deleted.insert(CourseTombstone.key(semester: selectedSemester, courseNo: course.courseNo))
        DataCache.shared.saveDeletedCourseNos(Array(deleted))

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

#if os(macOS)
import SwiftUI
import Defaults

/// Mutations the Mac grid can make to a schedule: add and remove a
/// user-added course, rename one, and delete one.
///
/// Every one of these writes an on-disk store keyed by `courseNo` alone, so
/// they are gated on `isViewingCurrentSemester` at the call site — a rename
/// made while looking at a past term would otherwise leak into the current
/// schedule, the widgets, and the Live Activity for any course that reuses
/// the code. iOS runs the same operations through `ClassTableViewModel`;
/// the Mac view has no view-model, which is why they live on the view.
extension MacClassTableView {
    // MARK: - User-added courses

    /// Append a user-added course to the on-disk store and refresh the grid.
    /// Mirrors the parts of `ClassTableViewModel.addCourse(_:)` that are load-
    /// bearing on macOS: tombstone clear, NameAbbr cache seeding so toggles
    /// round-trip without a refetch, and a `dataDidUpdate` broadcast so the
    /// Home page's widget cards also re-render. Returns `true` iff the
    /// course was newly persisted so the AddCourseSheet only flips its
    /// session checkmark on real adds — otherwise a duplicate-rejected tap
    /// would route the next tap through `removeUserAddedCourse` and delete
    /// the pre-existing user-added course for this semester.
    @discardableResult
    func addUserCourse(_ course: SDCourse) -> Bool {
        let existing = DataCache.shared.loadUserAddedCourses()
        // Dedupe within the selected semester only — the same `courseNo`
        // legitimately recurs across terms (a recurring elective added
        // manually in both 1131 and 1132), and `removeUserAddedCourse`
        // already scopes its undo to `selectedSemester`. `courses`
        // already reflects the current semester's roster so its
        // duplicate check stays semester-scoped implicitly.
        let isInSelectedSemester: (SDCourse) -> Bool = {
            $0.semester == selectedSemester || $0.semester.isEmpty
        }
        guard !existing.contains(where: { $0.courseNo == course.courseNo && isInSelectedSemester($0) }),
              !courses.contains(where: { $0.courseNo == course.courseNo })
        else { return false }

        // Refuse if any slot the candidate would occupy already has 2
        // courses. The shared `ClassTableLayout` can render N-way conflicts,
        // but persisting 3+ in a slot is still a bug surface (Android caps
        // at 2 and the iPhone path rejects too). Must run BEFORE tombstone
        // clear, otherwise a rejected add leaves a tombstone cleared and the
        // next reload would resurrect the course.
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

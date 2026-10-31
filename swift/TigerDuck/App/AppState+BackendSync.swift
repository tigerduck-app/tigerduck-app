import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    @discardableResult
    func syncOverridesFromBackend(followUpIfBusy: Bool = false) async -> FullSyncOutcome {
        await fullSyncRunner.sync(followUpIfBusy: followUpIfBusy)
    }

    /// Whether a full sync's error is its own cancellation, as at the time limit of a sync trigger
    /// push, which says nothing about the server. `URLSession` throws `URLError.cancelled` for it.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func retryUnsentEdits() async {
        retryUnacknowledgedHolidayOverrides()
        #if os(iOS)
        retryUnacknowledgedNotificationSettings()
        #endif
        await cloudSyncCoordinator.requeueParkedMarks()
    }

    nonisolated static func uploadsLocalMarksAsFirstSync(
        syncedBefore: Bool,
        serverHasMarks: Bool,
        localHasMarks: Bool
    ) -> Bool {
        !syncedBefore && !serverHasMarks && localHasMarks
    }

    nonisolated static func mergedMarks(
        server: Set<String>,
        local: Set<String>,
        protected: Set<String>
    ) -> Set<String> {
        server.subtracting(protected).union(local.intersection(protected))
    }

    nonisolated static func assignmentMarksToClear(server: Set<String>, local: Set<String>) -> Set<String> {
        server.subtracting(local)
    }

    nonisolated struct ServerIgnoredCourse: Equatable {
        let semester: String
        let courseNo: String
        let moodleId: String?
        let moodleCourseId: Int?

        var key: String { CourseTombstone.key(semester: semester, courseNo: courseNo) }
    }

    nonisolated static func serverIgnoredCourses(
        _ overrides: [[String: Any]],
        syncsCourses: Bool
    ) -> [ServerIgnoredCourse]? {
        guard syncsCourses, overrides.allSatisfy({ $0["ignore_assignments"] != nil }) else { return nil }
        return overrides.compactMap { row in
            guard row["ignore_assignments"] as? Bool == true,
                  let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return ServerIgnoredCourse(
                semester: semester,
                courseNo: courseNo,
                moodleId: row["moodle_id"] as? String ?? (row["moodle_id"] as? Int).map(String.init),
                moodleCourseId: row["moodle_course_id"] as? Int
            )
        }
    }

    nonisolated static func mergedIgnoredCourses(
        server: Set<String>,
        local: Set<String>,
        protected: Set<String>,
        snapshotSemesters: Set<String>
    ) -> Set<String> {
        let isCovered = { (key: String) in
            CourseTombstone.parts(of: key).map { snapshotSemesters.contains($0.semester) } ?? false
        }
        return local.filter { !isCovered($0) }.union(mergedMarks(
            server: server.filter(isCovered),
            local: local.filter(isCovered),
            protected: protected
        ))
    }

    nonisolated static func courseIgnoresToClear(
        server: [ServerIgnoredCourse],
        local: Set<String>
    ) -> [ServerIgnoredCourse] {
        server.filter { !local.contains($0.key) }
    }

    nonisolated static func serverDecidedCourses(_ overrides: [[String: Any]]) -> Set<String> {
        Set(overrides.compactMap { row in
            guard row["ignore_assignments"] as? Bool == true || row["ignore_assignments_updated_at"] is String,
                  let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
    }

    nonisolated static func listedCourseRows(_ courses: [[String: Any]]) -> [String: Int] {
        var rows: [String: Int] = [:]
        for row in courses {
            guard let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty,
                  let id = row["id"] as? Int
            else { continue }
            rows[CourseTombstone.key(semester: semester, courseNo: courseNo)] = id
        }
        return rows
    }

    nonisolated static func recreatedCourses(listed: [String: Int], seen: [String: Int]) -> Set<String> {
        let survivingTerms = Set(listed.compactMap { key, id in
            seen[key] == id ? CourseTombstone.parts(of: key)?.semester : nil
        })
        return Set(listed.compactMap { key, id in
            guard let old = seen[key], old != id,
                  let semester = CourseTombstone.parts(of: key)?.semester, survivingTerms.contains(semester)
            else { return nil }
            return key
        })
    }

    nonisolated static func listedCourses(_ courses: [[String: Any]]) -> Set<String> {
        Set(courses.compactMap { row in
            guard let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
    }

    nonisolated static func courseKeysPullLeaves(
        _ keys: Set<String>,
        deleting: Set<String>,
        resetSemesters: Set<String>
    ) -> Set<String> {
        keys.filter { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return false }
            return CourseTombstone.isHidden(courseNo, semester: semester, in: deleting) || resetSemesters.contains(semester)
        }
    }

    nonisolated static func ignoredCoursesAfterPull(
        server: Set<String>,
        decided: Set<String>,
        listed: Set<String>,
        local: Set<String>,
        protected: Set<String>,
        snapshotSemesters: Set<String>
    ) -> (ignored: Set<String>, resend: Set<String>) {
        let resend = local.intersection(listed).subtracting(decided).subtracting(protected)
        let ignored = mergedIgnoredCourses(
            server: server, local: local, protected: protected.union(resend), snapshotSemesters: snapshotSemesters
        )
        return (ignored, resend)
    }

    nonisolated static func ignoredCoursesDiffer(
        server: Set<String>?,
        decided: Set<String>,
        listed: Set<String>,
        local: Set<String>,
        snapshotSemesters: Set<String>
    ) -> Bool {
        guard let server else { return false }
        return ignoredCoursesAfterPull(
            server: server, decided: decided, listed: listed, local: local, protected: [],
            snapshotSemesters: snapshotSemesters
        ).ignored != local
    }

    static func moodleCourseIdsToSend(
        _ server: [ServerIgnoredCourse],
        protected: Set<String>,
        lookup: (String) -> Int?
    ) -> [(course: ServerIgnoredCourse, moodleId: String, moodleCourseId: Int)] {
        server.compactMap { course in
            guard course.moodleCourseId == nil, !protected.contains(course.key),
                  let moodleId = course.moodleId, let moodleCourseId = lookup(moodleId)
            else { return nil }
            return (course, moodleId, moodleCourseId)
        }
    }

    func applyIgnoredCourses(
        _ server: [ServerIgnoredCourse],
        decided: Set<String>,
        coursesArray: [[String: Any]],
        protected: Set<String>,
        deleting queuedDeletes: Set<String>,
        fetchedAt: Date
    ) -> Bool {
        let now = Date()
        let deleting = recentCourseDeletions.filter { now.timeIntervalSince($0.value) < Self.courseDeleteGraceInterval }
        let resetSemesters = resettingSemesters.union(
            CourseStore.shared.loadSemesterResetAt().filter { $0.value > fetchedAt }.keys
        )
        let current = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        let listed = Self.listedCourses(coursesArray)
        let listedRows = Self.listedCourseRows(coursesArray)
        let recreated = Self.recreatedCourses(listed: listedRows, seen: Defaults[.courseRowIdsSeen])
        Defaults[.courseRowIdsSeen] = listedRows
        let protected = protected.union(Self.courseKeysPullLeaves(
            Set(server.map(\.key)).union(listed).union(current),
            deleting: Set(deleting.keys).union(queuedDeletes),
            resetSemesters: resetSemesters
        ))
        let missingIds = Self.moodleCourseIdsToSend(server, protected: protected) {
            MoodleFiles.shared.lookupMoodleCourseId(idnumber: $0)
        }
        for (course, moodleId, moodleCourseId) in missingIds {
            Task { [weak self] in
                await self?.cloudSyncCoordinator.enqueueCourseIgnore(
                    semester: course.semester, courseNo: course.courseNo, moodleId: moodleId,
                    moodleCourseId: moodleCourseId, ignore: nil)
            }
        }
        if !missingIds.isEmpty { cloudSyncCoordinator.scheduleTick(after: 1) }

        let (merged, resend) = Self.ignoredCoursesAfterPull(
            server: Set(server.map(\.key)),
            decided: decided.union(recreated),
            listed: listed,
            local: current,
            protected: protected,
            snapshotSemesters: Set(coursesArray.compactMap { $0["semester"] as? String })
        )
        if !resend.isEmpty {
            AppLogger.sync.info("[syncOverrides] sending \(resend.count, privacy: .public) course settings the server lost again")
            syncCourseIgnores(resend)
        }
        guard merged != current else { return false }
        AssignmentStore.shared.replaceIgnoredAssignmentCourses(merged)
        return true
    }

    /// A backend timestamp: Python `isoformat()`, which has microseconds unless they are zero.
    static func backendDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return TigerDuckDateFormatters.withFractional.date(from: raw)
            ?? TigerDuckDateFormatters.withoutFractional.date(from: raw)
    }

    nonisolated static func coursesReset(
        server: Date?, lastSeen: Date?, takesCourses: Bool
    ) -> (apply: Bool, remember: Date) {
        guard let lastSeen else { return (false, server ?? .distantPast) }
        guard let server else { return (false, lastSeen) }
        return (takesCourses && server > lastSeen, server)
    }

    static func recordFullSync(coursesReset: Date, taken: Set<String>) {
        Defaults[.lastSeenCoursesResetAt] = coursesReset
        Defaults[.categoriesSyncedOnce].formUnion(taken)
    }

    nonisolated static func fullSyncMayWrite(
        signedOutSince: Bool, cloudSyncEnabled: Bool, protectedDataAvailable: Bool
    ) -> Bool {
        !signedOutSince && cloudSyncEnabled && protectedDataAvailable
    }

    func fullSyncMayWrite(since ticket: AccountSession.Ticket) -> Bool {
        #if os(iOS)
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        #else
        let protectedDataAvailable = true
        #endif
        return Self.fullSyncMayWrite(
            signedOutSince: !authService.session.isCurrent(ticket),
            cloudSyncEnabled: Defaults[.cloudSyncEnabled],
            protectedDataAvailable: protectedDataAvailable
        )
    }

    func applyCourseOverrides(
        _ overrides: [[String: Any]], coursesArray: [[String: Any]], colors: Bool, names: Bool,
        holdingColors: Set<String>, holdingNames: Set<String>
    ) -> Bool {
        var moodleIdToNo: [String: String] = [:]
        for c in coursesArray {
            guard let mId = Self.overrideIdentity(c) else { continue }
            if let courseNo = c["course_no"] as? String, !courseNo.isEmpty {
                moodleIdToNo[mId] = courseNo
            } else if let name = c["course_name"] as? String, let bracketEnd = name.firstIndex(of: "】") {
                let rest = name[name.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
                let code = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if !code.isEmpty { moodleIdToNo[mId] = code }
            }
        }
        AppLogger.sync.info("moodleIdToNo: \(moodleIdToNo.count, privacy: .public) entries, overrides: \(overrides.count, privacy: .public)")

        let colorsChanged = colors && TigerDuckTheme.applyColors(
            Self.serverCourseColors(overrides, courseNos: moodleIdToNo, holding: holdingColors)
        )
        let namesBefore = CourseStore.shared.loadCourseCustomNames()
        let customNames = names
            ? Self.courseNamesAfterPull(overrides, courseNos: moodleIdToNo, local: namesBefore, holding: holdingNames)
            : namesBefore
        let namesChanged = customNames != namesBefore
        if namesChanged {
            CourseStore.shared.saveCourseCustomNames(customNames)
        }
        return colorsChanged || namesChanged
    }

    nonisolated static func courseNamesAfterPull(
        _ overrides: [[String: Any]],
        courseNos: [String: String],
        local: [String: [String: String]],
        holding held: Set<String>
    ) -> [String: [String: String]] {
        var names = local
        for o in overrides {
            guard let mId = overrideIdentity(o), !held.contains(mId),
                  let courseNo = o["course_no"] as? String ?? courseNos[mId],
                  let serverNames = o["custom_names"] as? [String: String], !serverNames.isEmpty
            else { continue }
            var existing = names[courseNo] ?? [:]
            for (locale, name) in serverNames {
                if name.isEmpty {
                    existing.removeValue(forKey: locale)
                } else {
                    existing[locale] = name
                }
            }
            names[courseNo] = existing.isEmpty ? nil : existing
        }
        return names
    }

    static func serverCourseColors(
        _ overrides: [[String: Any]],
        courseNos: [String: String],
        holding held: Set<String>
    ) -> [(courseNo: String, hex: UInt32)] {
        let rows = overrides.compactMap { o -> (courseNo: String, hex: UInt32, at: Date)? in
            guard let mId = overrideIdentity(o), !held.contains(mId),
                  let courseNo = o["course_no"] as? String ?? courseNos[mId],
                  let colorHex = o["color_hex"] as? String, !colorHex.isEmpty,
                  let hex = UInt32(colorHex.dropFirst(), radix: 16) else { return nil }
            let at = (o["color_hex_updated_at"] as? String).flatMap {
                TigerDuckDateFormatters.withFractional.date(from: $0)
                    ?? TigerDuckDateFormatters.withoutFractional.date(from: $0)
            } ?? .distantPast
            return (courseNo, hex, at)
        }
        return rows.sorted { ($0.at, $0.courseNo) < ($1.at, $1.courseNo) }.map { ($0.courseNo, $0.hex) }
    }

    /// How a snapshot's course or override row names its course, as this device's edits do: the
    /// Moodle id number, or the term and the number when it has none.
    nonisolated static func overrideIdentity(_ row: [String: Any]) -> String? {
        if let moodleId = row["moodle_id"] as? String ?? (row["moodle_id"] as? Int).map(String.init), !moodleId.isEmpty {
            return moodleId
        }
        guard let semester = row["semester"] as? String, let courseNo = row["course_no"] as? String,
              !semester.isEmpty, !courseNo.isEmpty else { return nil }
        return "\(semester)\(courseNo)"
    }

    /// `refused` is the access token the request that got the 401 sent.
    func attemptBackendRelogin(replacing refused: String?) async -> Bool {
        guard await authService.reloginToBackend(replacing: refused) else { return false }
        pushCoordinator.refreshRegistrationAfterAuth()
        return true
    }

    @discardableResult
    func syncAssignmentOverride(moodleId: String, status: String) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled], Defaults[.syncAssignments] else { return nil }
        AppLogger.sync.debug("override enqueue: \(moodleId, privacy: .private) → \(status, privacy: .public)")
        guard let moodleAssignmentId = Int(moodleId) else { return nil }
        overrideEditGeneration &+= 1
        pendingOverrides.insert(moodleId)
        let queued = Task { [weak self] in
            guard let self else { return }
            await cloudSyncCoordinator.enqueueAssignmentOverride(
                moodleCourseId: 0,
                moodleAssignmentId: moodleAssignmentId,
                localStatus: status)
            pendingOverrides.remove(moodleId)
        }
        cloudSyncCoordinator.scheduleTick(after: 1)
        revisionPoller.noteActivity()
        return queued
    }

    @discardableResult
    func syncCourseIgnore(semester: String, courseNo: String, moodleIdNumber: String?, ignore: Bool) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled] else { return nil }
        let moodleId = moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "\(semester)\(courseNo)"
        let moodleCourseId = MoodleFiles.shared.lookupMoodleCourseId(idnumber: moodleId)
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        overrideEditGeneration &+= 1
        pendingOverrides.insert(key)
        let queued = Task { [weak self] in
            guard let self else { return }
            await cloudSyncCoordinator.enqueueCourseIgnore(
                semester: semester, courseNo: courseNo, moodleId: moodleId,
                moodleCourseId: moodleCourseId, ignore: ignore)
            pendingOverrides.remove(key)
        }
        cloudSyncCoordinator.scheduleTick(after: 1)
        revisionPoller.noteActivity()
        return queued
    }

    @discardableResult
    func syncCourseIgnores(_ keys: Set<String>) -> [Task<Void, Never>?] {
        keys.sorted().map { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return nil }
            let course = (CourseStore.shared.loadCourses(semester: semester)
                + CourseStore.shared.loadUserAddedCourses(semester: semester)).first { $0.courseNo == courseNo }
            return syncCourseIgnore(semester: semester, courseNo: courseNo, moodleIdNumber: course?.moodleIdNumber, ignore: true)
        }
    }

    @discardableResult
    func syncCourseOverride(
        moodleCourseId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil
    ) -> [Task<Void, Never>?] {
        guard Defaults[.cloudSyncEnabled] else { return [] }
        let semester = CourseSelectionService.currentSemesterCode()
        let queued = [
            colorHex.flatMap {
                cloudSyncCoordinator.enqueueCourseColorOverride(moodleId: moodleCourseId, semester: semester, colorHex: $0)
            },
            customName.flatMap {
                cloudSyncCoordinator.enqueueCourseNameOverride(
                    moodleId: moodleCourseId, semester: semester, customName: $0, locale: locale)
            },
        ]
        cloudSyncCoordinator.scheduleTick(after: 1)
        revisionPoller.noteActivity()
        return queued
    }

    func deleteBackendCourse(courseNo: String, semester: String) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let hiddenAt = Date()
        recentCourseDeletions[courseNo] = hiddenAt
        revisionPoller.noteActivity()
        Task { await cloudSyncCoordinator.deleteCourse(semester: semester, courseNo: courseNo, at: hiddenAt) }
    }

    @discardableResult
    func deleteBackendCourses(
        semester: String? = nil,
        thenLocally resetLocally: @MainActor () -> Void = {}
    ) async -> Bool {
        guard Defaults[.cloudSyncEnabled] else {
            resetLocally()
            return true
        }
        if let semester { resettingSemesters.insert(semester) }
        defer { if let semester { resettingSemesters.remove(semester) } }
        let madeAt = Date()
        do {
            try await Self.resetCourses(semester: semester, on: cloudSyncCoordinator, onServer: { [pushCoordinator] in
                try await pushCoordinator.deleteAllCourses(semester: semester, madeAt: madeAt)
                AppLogger.sync.info("deleteBackendCourses ok: \(semester ?? "all", privacy: .public)")
                if let semester { CourseStore.shared.recordSemesterReset(semester) }
                pushCoordinator.forgetUploads(semester: semester)
            }, thenLocally: resetLocally)
            return true
        } catch {
            AppLogger.sync.error("deleteBackendCourses failed: \(error, privacy: .private)")
            return false
        }
    }

    /// Resets the courses on the server, then clears them here and drops the deletes queued until
    /// that moment, so a hide made during the request is gone from both and a later one kept in both.
    static func resetCourses(
        semester: String?, on coordinator: CloudSyncCoordinator,
        onServer reset: () async throws -> Void, thenLocally resetLocally: () -> Void
    ) async throws {
        try await reset()
        let resetAt = Date()
        resetLocally()
        await coordinator.discardCourseIgnores(semester: semester)
        await coordinator.discardCourseDeletes(semester: semester, madeBefore: resetAt)
    }

    func uploadCourses(
        _ courses: [SDCourse], semester: String, forceKeys: [String] = [], asRoster: Bool = false, resend: Bool = false
    ) {
        if !forceKeys.isEmpty {
            let addedAt = Date()
            Task { await cloudSyncCoordinator.discardCourseDeletes(courseKeys: Set(forceKeys), madeBefore: addedAt) }
        }
        guard SyncPolicy.current.uploadsCourses else { return }
        guard forceKeys.isEmpty else {
            let prefix = CourseTombstone.serverKey(semester: semester, courseNo: "")
            for key in forceKeys where key.hasPrefix(prefix) {
                cloudSyncCoordinator.addCourse(semester: semester, courseNo: String(key.dropFirst(prefix.count)))
            }
            return
        }
        let request = Self.courseUploadRequest(courses, semester: semester, rosterTerms: asRoster ? [semester] : nil)
        let ticket = authService.session.ticket
        let coordinator = pushCoordinator
        Task { [weak self] in
            await self?.sendUpload("uploadCourses \(semester)", ticket: ticket) { isCurrent in
                try await coordinator.uploadCoursesIfChanged(
                    request, semester: semester, resend: resend, isCurrent: isCurrent
                )
            }
        }
    }

    /// The added course alone: sent with its stamp, the backend files every other course an upload
    /// lists as the school's roster.
    static func addedCourseUpload(
        semester: String, courseNo: String, courses: CourseStore = .shared
    ) -> PushAPI.CourseUploadRequest? {
        let shown = CanonicalCourseProvider(courses: courses).currentCourses(semester: semester)
        guard let course = shown.first(where: { $0.courseNo == courseNo }) else { return nil }
        return courseUploadRequest([course], semester: semester)
    }

    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest) {
        guard SyncPolicy.current.cloudSyncEnabled else { return }
        let ticket = authService.session.ticket
        let coordinator = pushCoordinator
        Task { [weak self] in
            await self?.sendUpload("uploadAssignments", ticket: ticket) { isCurrent in
                try await coordinator.uploadAssignmentsIfChanged(request, isCurrent: isCurrent)
            }
        }
    }

    /// Sends what this device derived from school data once this sign-in's first pull has been
    /// applied (`SyncTarget`).
    private func sendUpload(
        _ label: String,
        ticket: AccountSession.Ticket,
        _ send: (_ isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    ) async {
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            self?.authService.session.isCurrent(ticket) == true && Defaults[.cloudSyncEnabled]
        }
        guard isCurrent(), await syncTarget.waitForPull(ticket), isCurrent() else { return }
        do {
            let sent = try await send(isCurrent)
            AppLogger.sync.info("\(label, privacy: .public): \(sent ? "sent" : "skipped", privacy: .public)")
        } catch {
            AppLogger.sync.error("\(label, privacy: .public) failed: \(error, privacy: .private)")
        }
    }

    /// The school's courses of `semester`. Their colours do not go here: `/v4` takes a colour
    /// only through the course override.
    static func courseUploadRequest(
        _ courses: [SDCourse],
        semester: String,
        rosterTerms: [String]? = nil
    ) -> PushAPI.CourseUploadRequest {
        let entries = courses.map { c in
            PushAPI.CourseUploadEntry(
                semester: semester,
                courseNo: c.courseNo,
                courseName: c.courseName,
                courseNameEn: nil,
                moodleId: c.moodleIdNumber,
                credits: c.credits > 0 ? c.credits : nil,
                classroom: c.classroom.isEmpty ? nil : c.classroom,
                instructors: c.instructor.isEmpty ? [] : [c.instructor],
                scheduleJson: c.schedule.isEmpty ? nil : Dictionary(uniqueKeysWithValues: c.schedule.map { ("\($0.key)", $0.value) }),
                classroomMap: c.classroomMap.isEmpty ? nil : c.classroomMap
            )
        }
        return PushAPI.CourseUploadRequest(courses: entries, rosterTerms: rosterTerms)
    }
}

@MainActor
final class FullSyncGate {
    private(set) var isRunning = false
    private var queued: [Int: CheckedContinuation<FullSyncOutcome, Never>] = [:]
    private var following: [Int: CheckedContinuation<FullSyncOutcome, Never>] = [:]
    private var runningFollowUp: Task<Void, Never>?
    private var lastTicket = 0

    var queuedFollowUps: Int { queued.count }

    func run(
        followUp: Bool, mayFollow: @escaping () -> Bool, _ body: @escaping () async -> FullSyncOutcome
    ) async -> FullSyncOutcome {
        guard !isRunning else {
            guard followUp else { return .skipped }
            return await waitForFollowUp()
        }
        isRunning = true
        let outcome = await body()
        follow(mayFollow: mayFollow, body)
        return outcome
    }

    private func waitForFollowUp() async -> FullSyncOutcome {
        lastTicket += 1
        let ticket = lastTicket
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if Task.isCancelled { waiter.resume(returning: .skipped) } else { queued[ticket] = waiter }
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(ticket) }
        }
    }

    private func giveUp(_ ticket: Int) {
        if let waiter = queued.removeValue(forKey: ticket) {
            waiter.resume(returning: .skipped)
        } else if let waiter = following.removeValue(forKey: ticket) {
            waiter.resume(returning: .skipped)
            if following.isEmpty { runningFollowUp?.cancel() }
        }
    }

    private func follow(mayFollow: @escaping () -> Bool, _ body: @escaping () async -> FullSyncOutcome) {
        guard !queued.isEmpty, mayFollow() else {
            for waiter in queued.values { waiter.resume(returning: .skipped) }
            queued = [:]
            isRunning = false
            return
        }
        following = queued
        queued = [:]
        runningFollowUp = Task {
            let outcome: FullSyncOutcome = if Task.isCancelled { .skipped } else { await body() }
            for waiter in following.values { waiter.resume(returning: outcome) }
            following = [:]
            follow(mayFollow: mayFollow, body)
        }
    }
}

import Foundation

private struct CourseData: Sendable {
    let courseNo: String
    let courseName: String
    let instructor: String
    let credits: Int
    let classroom: String
    let enrolledCount: Int
    let maxCount: Int
    let schedule: [Int: [String]]
    let moodleIdNumber: String
    let classroomMap: [String: String]
}

enum AppServiceBridge {

    /// Fetch and enrich enrolled courses.
    ///
    /// Pass `forceRefresh: true` to bust the `CourseService`
    /// enrolled-course-nos cache (ClassTable pull-to-refresh does this);
    /// default `false` lets the 24h cache absorb cheap refreshes.
    static func fetchCourses(
        authService: AuthService,
        forceRefresh: Bool = false
    ) async -> [SDCourse] {
        // Snapshot the login generation before issuing the network call.
        // Any logout that happens while we are awaiting will bump this
        // counter, and the post-fetch save below skips the write so the
        // previous user's data does not land in DataCache after
        // `clearUserScopedData()` has already run.
        let startGeneration = authService.loginGeneration
        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else {
            return DataCache.shared.loadCourses()
        }

        do {
            let session = NTUSTSessionManager.shared.session
            let courseNos = try await CourseService.fetchEnrolledCourseNos(
                session: session,
                studentId: studentId,
                password: password,
                forceRefresh: forceRefresh
            )

            let semester = CourseService.currentSemesterCode()

            let courseDataList = await withTaskGroup(of: CourseData?.self) { group in
                for courseNo in courseNos {
                    group.addTask {
                        let results: [CourseSearchResult]
                        do {
                            results = try await CourseService.lookupCourse(
                                semester: semester, courseNo: courseNo
                            )
                        } catch {
                            await MainActor.run {
                                AppLogger.captureError(error, context: [
                                    "service": "courseLookup",
                                    "semester": semester,
                                    "courseNo": courseNo,
                                ])
                            }
                            return nil
                        }

                        guard let first = results.first else { return nil }

                        // Merge schedules and classrooms from all rows
                        // (same course can have multiple time slots / classrooms)
                        var mergedSchedule: [Int: [String]] = [:]
                        var classroomMap: [String: String] = [:]
                        var allClassrooms: [String] = []
                        var seenClassrooms = Set<String>()

                        for row in results {
                            let partial = CourseService.parseNodeToSchedule(row.Node)
                            // API may return "教室A、教室A" — reuse SDCourse helpers to split/dedup
                            var seenParts = Set<String>()
                            let uniqueParts = SDCourse.splitRoom(row.ClassRoomNo ?? "")
                                .filter { seenParts.insert($0).inserted }
                            let room = uniqueParts.joined(separator: ", ")

                            for (day, periods) in partial {
                                mergedSchedule[day, default: []].append(contentsOf: periods)
                                if !room.isEmpty {
                                    for period in periods {
                                        classroomMap["\(day)-\(period)"] = room
                                    }
                                }
                            }

                            for part in uniqueParts where !seenClassrooms.contains(part) {
                                seenClassrooms.insert(part)
                                allClassrooms.append(part)
                            }
                        }

                        let credits = Int(first.CreditPoint) ?? 0
                        let enrolled = first.ChooseStudent ?? 0
                        let maxCount = Int(first.Restrict2 ?? "0") ?? 0

                        return CourseData(
                            courseNo: first.CourseNo,
                            courseName: first.CourseName,
                            instructor: first.CourseTeacher,
                            credits: credits,
                            classroom: allClassrooms.joined(separator: ", "),
                            enrolledCount: enrolled,
                            maxCount: maxCount,
                            schedule: mergedSchedule,
                            moodleIdNumber: "\(first.Semester)\(first.CourseNo)",
                            classroomMap: classroomMap
                        )
                    }
                }

                var results: [CourseData] = []
                for await data in group {
                    if let d = data { results.append(d) }
                }
                return results
            }
            let courses = courseDataList.map { d in
                SDCourse(
                    courseNo: d.courseNo,
                    courseName: d.courseName,
                    instructor: d.instructor,
                    credits: d.credits,
                    classroom: d.classroom,
                    enrolledCount: d.enrolledCount,
                    maxCount: d.maxCount,
                    schedule: d.schedule,
                    moodleIdNumber: d.moodleIdNumber,
                    classroomMap: d.classroomMap
                )
            }

            // Drop the cache write when either the calling Task was
            // cancelled (covers AppState.syncTask in the background sync
            // path) or the login generation moved on (covers Home /
            // ClassTable / Calendar refresh paths whose Task is not owned
            // by AppState and therefore is not reached by syncTask?.cancel()).
            if !courses.isEmpty,
               !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveCourses(courses)
            }
            return courses
        } catch {
            await MainActor.run {
                AppLogger.captureError(error, context: ["bridge": "fetchCourses"])
            }
            return DataCache.shared.loadCourses()
        }
    }

    static func fetchAssignments(authService: AuthService) async -> [SDAssignment] {
        let startGeneration = authService.loginGeneration
        // MoodleAssignmentBridgeService runs on its own long-lived OIDC
        // token; credentials are only needed so that a token refresh can
        // reach Keychain. If the user logged out, fall back to cache.
        guard authService.storedStudentId != nil,
              authService.storedPassword != nil else {
            return DataCache.shared.loadAssignments()
        }

        do {
            let assignments = try await MoodleAssignmentBridgeService.fetchAssignments()
            let mergedAssignments = preserveCompletionState(
                freshAssignments: assignments,
                cachedAssignments: DataCache.shared.loadAssignments(),
            )
            // Same dual guard as fetchCourses above: cancellation OR a
            // logout that bumped loginGeneration must drop the save.
            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveAssignments(mergedAssignments)
            }
            return mergedAssignments
        } catch {
            await MainActor.run {
                AppLogger.captureError(error, context: ["bridge": "fetchAssignments"])
            }
            return DataCache.shared.loadAssignments()
        }
    }

    static func preserveCompletionState(
        freshAssignments: [SDAssignment],
        cachedAssignments: [SDAssignment]
    ) -> [SDAssignment] {
        let completedIds = Set(
            cachedAssignments
                .filter(\.isCompleted)
                .map(\.assignmentId)
        )

        for assignment in freshAssignments where completedIds.contains(assignment.assignmentId) {
            assignment.isCompleted = true
        }

        return freshAssignments
    }

}

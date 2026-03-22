import Foundation

enum KMPServiceBridge {

    static func fetchCourses(authService: AuthService) async -> [SDCourse] {
        guard let studentId = authService.storedStudentId else {
            return DataCache.shared.loadCourses()
        }

        guard await authService.ensureAuthenticated() else {
            return DataCache.shared.loadCourses()
        }

        guard let pwData = KeychainManager.load(key: "ntust_password"),
              let password = String(data: pwData, encoding: .utf8) else {
            return DataCache.shared.loadCourses()
        }

        do {
            let session = NTUSTSessionManager.shared.session
            let courseNos = try await CourseService.fetchEnrolledCourseNos(
                session: session,
                studentId: studentId,
                password: password
            )

            let semester = CourseService.currentSemesterCode()

            let courses = await withTaskGroup(of: SDCourse?.self) { group in
                for courseNo in courseNos {
                    group.addTask {
                        guard let results = try? await CourseService.lookupCourse(
                            semester: semester, courseNo: courseNo
                        ), let first = results.first else { return nil }

                        // Merge schedules and classrooms from all rows
                        // (same course can have multiple time slots / classrooms)
                        var mergedSchedule: [Int: [String]] = [:]
                        var classrooms: [String] = []
                        for row in results {
                            let partial = CourseService.parseNodeToSchedule(row.Node)
                            for (day, periods) in partial {
                                mergedSchedule[day, default: []].append(contentsOf: periods)
                            }
                            if let room = row.ClassRoomNo, !room.isEmpty, !classrooms.contains(room) {
                                classrooms.append(room)
                            }
                        }

                        let credits = Int(first.CreditPoint) ?? 0
                        let enrolled = first.ChooseStudent ?? 0
                        let maxCount = Int(first.Restrict2 ?? "0") ?? 0

                        return SDCourse(
                            courseNo: first.CourseNo,
                            courseName: first.CourseName,
                            instructor: first.CourseTeacher,
                            credits: credits,
                            classroom: classrooms.joined(separator: ", "),
                            enrolledCount: enrolled,
                            maxCount: maxCount,
                            schedule: mergedSchedule,
                            moodleIdNumber: "\(first.Semester)\(first.CourseNo)"
                        )
                    }
                }

                var results: [SDCourse] = []
                for await course in group {
                    if let c = course { results.append(c) }
                }
                return results
            }

            if !courses.isEmpty {
                DataCache.shared.saveCourses(courses)
                NotificationCenter.default.post(name: AppConstants.Notifications.dataDidUpdate, object: nil)
            }
            return courses
        } catch {
            let cached = DataCache.shared.loadCourses()
            return cached.isEmpty ? MockData.courses : cached
        }
    }

    static func fetchAssignments(authService: AuthService) async -> [SDAssignment] {
        guard let studentId = authService.storedStudentId else {
            return DataCache.shared.loadAssignments()
        }

        guard await authService.ensureAuthenticated() else {
            return DataCache.shared.loadAssignments()
        }

        guard let pwData = KeychainManager.load(key: "ntust_password"),
              let password = String(data: pwData, encoding: .utf8) else {
            return DataCache.shared.loadAssignments()
        }

        do {
            let session = NTUSTSessionManager.shared.session
            let assignments = try await MoodleService.fetchAssignments(
                session: session,
                studentId: studentId,
                password: password
            )
            DataCache.shared.saveAssignments(assignments)
            NotificationCenter.default.post(name: AppConstants.Notifications.dataDidUpdate, object: nil)
            return assignments
        } catch {
            let cached = DataCache.shared.loadAssignments()
            return cached.isEmpty ? MockData.assignments : cached
        }
    }

    static func fetchAnnouncements() async -> [SDAnnouncement] {
        MockData.announcements
    }

    static func fetchCalendarEvents() async -> [SDCalendarEvent] {
        MockData.calendarEvents
    }
}

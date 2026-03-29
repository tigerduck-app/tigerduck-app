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

enum KMPServiceBridge {

    static func fetchCourses(authService: AuthService) async -> [SDCourse] {
        guard let studentId = authService.storedStudentId else {
            return DataCache.shared.loadCourses()
        }

        guard await authService.ensureAuthenticated() else {
            return DataCache.shared.loadCourses()
        }

        guard let password = authService.storedPassword else {
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

            let courseDataList = await withTaskGroup(of: CourseData?.self) { group in
                for courseNo in courseNos {
                    group.addTask {
                        guard let results = try? await CourseService.lookupCourse(
                            semester: semester, courseNo: courseNo
                        ), let first = results.first else { return nil }

                        // Merge schedules and classrooms from all rows
                        // (same course can have multiple time slots / classrooms)
                        var mergedSchedule: [Int: [String]] = [:]
                        var classroomMap: [String: String] = [:]
                        var allClassrooms: [String] = []
                        var seenClassrooms = Set<String>()

                        for row in results {
                            let partial = CourseService.parseNodeToSchedule(row.Node)
                            let room = row.ClassRoomNo?.trimmingCharacters(in: .whitespaces) ?? ""

                            for (day, periods) in partial {
                                mergedSchedule[day, default: []].append(contentsOf: periods)
                                if !room.isEmpty {
                                    for period in periods {
                                        classroomMap["\(day)-\(period)"] = room
                                    }
                                }
                            }

                            if !room.isEmpty, !seenClassrooms.contains(room) {
                                seenClassrooms.insert(room)
                                allClassrooms.append(room)
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

            if !courses.isEmpty {
                DataCache.shared.saveCourses(courses)
            }
            return courses
        } catch {
            return DataCache.shared.loadCourses()
        }
    }

    static func fetchAssignments(authService: AuthService) async -> [SDAssignment] {
        guard let studentId = authService.storedStudentId else {
            return DataCache.shared.loadAssignments()
        }

        guard await authService.ensureAuthenticated() else {
            return DataCache.shared.loadAssignments()
        }

        guard let password = authService.storedPassword else {
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
            return assignments
        } catch {
            return DataCache.shared.loadAssignments()
        }
    }

}

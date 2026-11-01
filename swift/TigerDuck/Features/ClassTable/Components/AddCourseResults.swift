import Foundation

enum AddCourseResults {
    struct Course {
        let courseNo: String
        let primaryName: String
        let secondaryName: String?
        let instructor: String
        let credits: Double
        let classroom: String
        let classroomMap: [String: String]
        let enrolledCount: Int
        let maxCount: Int
        let schedule: [Int: [String]]
        let nodeDisplay: String
        let dimension: String
        let allYear: String
        let requireOption: String

        var displayName: String {
            guard let secondary = secondaryName,
                  !secondary.isEmpty,
                  secondary != primaryName
            else { return primaryName }
            return "\(primaryName) (\(secondary))"
        }

        func tableCourse(semester: String, name: String, instructor: String) -> CourseStore.Course {
            CourseStore.Course(
                courseNo: courseNo,
                courseName: name,
                instructor: instructor,
                credits: credits,
                classroom: classroom,
                enrolledCount: enrolledCount,
                maxCount: maxCount,
                schedule: schedule,
                moodleIdNumber: nil,
                semester: semester,
                classroomMap: classroomMap,
                dimension: dimension,
                allYear: allYear,
                requireOption: requireOption
            )
        }
    }

    struct Shown {
        let course: Course
        let conflicts: [String]
    }

    static func shown(
        _ results: [String: [CourseCatalogStore.Row]], language: String,
        table: [CourseSearchTableCourse], filters: CourseSearchFilters
    ) -> [Shown] {
        grouped(results, language: language).compactMap { course in
            CourseSearch.visibleConflicts(
                courseNo: course.courseNo, schedule: course.schedule, table: table, filters: filters
            ).map { Shown(course: course, conflicts: $0) }
        }
    }

    static func grouped(_ results: [String: [CourseCatalogStore.Row]], language: String) -> [Course] {
        let (rows, secondaryNamesByNo) = CourseSearch.shown(results, primary: language)
        var seen: [String: Course] = [:]
        var order: [String] = []

        for result in rows {
            let key = result.CourseNo
            let partial = CourseLookup.schedule(of: result.Node)
            var rowSeen = Set<String>()
            let rowRoomParts = CourseStore.Course.splitRoom(result.ClassRoomNo ?? "")
                .filter { rowSeen.insert($0).inserted }
            let rowRoom = rowRoomParts.joined(separator: ", ")

            if var existing = seen[key] {
                var merged = existing.schedule
                for (day, periods) in partial {
                    merged[day, default: []].append(contentsOf: periods)
                }
                let room = (result.ClassRoomNo ?? "").trimmingCharacters(in: .whitespaces)
                let existingRooms = existing.classroom.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let newClassroom = existing.classroom.isEmpty ? room :
                    (room.isEmpty || existingRooms.contains(room)) ? existing.classroom :
                    "\(existing.classroom), \(room)"
                let nodeStr = existing.nodeDisplay.isEmpty ? (result.Node ?? "") :
                    (result.Node == nil || result.Node!.isEmpty) ? existing.nodeDisplay :
                    "\(existing.nodeDisplay), \(result.Node!)"

                var mergedMap = existing.classroomMap
                if !rowRoom.isEmpty {
                    for (day, periods) in partial {
                        for period in periods {
                            mergedMap["\(day)-\(period)"] = rowRoom
                        }
                    }
                }

                existing = Course(
                    courseNo: existing.courseNo,
                    primaryName: existing.primaryName,
                    secondaryName: existing.secondaryName,
                    instructor: existing.instructor,
                    credits: existing.credits,
                    classroom: newClassroom,
                    classroomMap: mergedMap,
                    enrolledCount: existing.enrolledCount,
                    maxCount: existing.maxCount,
                    schedule: merged,
                    nodeDisplay: nodeStr,
                    dimension: existing.dimension.isEmpty ? (result.Dimension ?? "") : existing.dimension,
                    allYear: existing.allYear.isEmpty ? (result.AllYear ?? "") : existing.allYear,
                    requireOption: existing.requireOption.isEmpty ? (result.RequireOption ?? "") : existing.requireOption
                )
                seen[key] = existing
            } else {
                var initialMap: [String: String] = [:]
                if !rowRoom.isEmpty {
                    for (day, periods) in partial {
                        for period in periods {
                            initialMap["\(day)-\(period)"] = rowRoom
                        }
                    }
                }
                order.append(key)
                seen[key] = Course(
                    courseNo: result.CourseNo,
                    primaryName: result.CourseName,
                    secondaryName: secondaryNamesByNo[result.CourseNo],
                    instructor: result.CourseTeacher,
                    credits: Double(result.CreditPoint) ?? 0,
                    classroom: result.ClassRoomNo ?? "",
                    classroomMap: initialMap,
                    enrolledCount: result.ChooseStudent ?? 0,
                    maxCount: Int(result.Restrict2 ?? "0") ?? 0,
                    schedule: partial,
                    nodeDisplay: result.Node ?? "",
                    dimension: result.Dimension ?? "",
                    allYear: result.AllYear ?? "",
                    requireOption: result.RequireOption ?? ""
                )
            }
        }

        return order.compactMap { seen[$0] }
    }
}

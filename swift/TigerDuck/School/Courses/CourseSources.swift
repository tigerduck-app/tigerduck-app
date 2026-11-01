import Foundation

enum CourseSources {
    static func moodleCourses(for signIn: SignIn) async -> [MoodleEnrolledCourse]? {
        do {
            let courses = try await MoodleEnrolledCoursesService.fetchEnrolled()
            CourseFetch.record(.ok, for: .moodle, round: signIn)
            return courses
        } catch {
            CourseFetch.record(.failed, for: .moodle, round: signIn)
            AppLogger.captureError(error, context: ["service": "fetchEnrolled", "flow": "classTable"])
            return nil
        }
    }

    static func transcript(authService: AuthService, for signIn: SignIn) async -> ScoreReport? {
        guard let studentId = authService.storedStudentId,
              let password = authService.storedPassword else { return nil }
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.scoreSystem)
            #endif
            let report = try await NTUSTScoreService.fetchScoreReport(
                session: NTUSTSessionManager.shared.session,
                studentId: studentId,
                password: password,
                forceRefresh: false,
                for: signIn
            ).report
            CourseFetch.record(.ok, for: .scoreSystem, round: signIn)
            return report
        } catch {
            CourseFetch.record(.failed, for: .scoreSystem, round: signIn)
            AppLogger.captureError(error, context: ["service": "fetchScoreReport", "flow": "classTable"])
            return nil
        }
    }

    static func selectionCourseNos(
        authService: AuthService, studentId: String, password: String, semester: String,
        forceRefresh: Bool, for signIn: SignIn
    ) async -> (courseNos: [String], live: Bool)? {
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.courseSelection)
            #endif
            let answer = try await CourseSelectionService.fetchEnrolledCourseNos(
                session: NTUSTSessionManager.shared.session,
                studentId: studentId,
                password: password,
                forceRefresh: forceRefresh,
                for: signIn
            )
            await MainActor.run {
                CourseFetch.record(.ok, for: .courseSelection, round: signIn)
            }
            return (answer.courseNos, answer.live)
        } catch {
            await MainActor.run {
                CourseFetch.record(.failed, for: .courseSelection, round: signIn)
                AppLogger.captureError(error, context: [
                    "service": "fetchEnrolledCourseNos",
                    "semester": semester,
                    "fallback": "transcript",
                ])
            }
            return nil
        }
    }
}

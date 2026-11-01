import Foundation

enum CourseSources {
    static func moodleCourses(authService: AuthService) async -> [MoodleEnrolledCourse]? {
        let ticket = authService.session.ticket
        do {
            let courses = try await MoodleEnrolledCoursesService.fetchEnrolled()
            CourseFetch.record(.ok, for: .moodle, round: ticket, authService: authService)
            return courses
        } catch {
            CourseFetch.record(.failed, for: .moodle, round: ticket, authService: authService)
            AppLogger.captureError(error, context: ["service": "fetchEnrolled", "flow": "classTable"])
            return nil
        }
    }

    static func transcript(authService: AuthService) async -> ScoreReport? {
        let ticket = authService.session.ticket
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
                persistGuard: { @Sendable [weak authService] in
                    authService?.session.isCurrent(ticket) == true
                }
            ).report
            CourseFetch.record(.ok, for: .scoreSystem, round: ticket, authService: authService)
            return report
        } catch {
            CourseFetch.record(.failed, for: .scoreSystem, round: ticket, authService: authService)
            AppLogger.captureError(error, context: ["service": "fetchScoreReport", "flow": "classTable"])
            return nil
        }
    }

    static func selectionCourseNos(
        authService: AuthService, studentId: String, password: String, semester: String,
        forceRefresh: Bool, ticket: AccountSession.Ticket
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
                persistGuard: { @Sendable [weak authService] in
                    authService?.session.isCurrent(ticket) == true
                }
            )
            await MainActor.run {
                CourseFetch.record(.ok, for: .courseSelection, round: ticket, authService: authService)
            }
            return (answer.courseNos, answer.live)
        } catch {
            await MainActor.run {
                CourseFetch.record(.failed, for: .courseSelection, round: ticket, authService: authService)
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

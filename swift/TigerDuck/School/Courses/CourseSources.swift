import Foundation

/// The answers a term's course list is drawn from, each recorded in the server status.
enum CourseSources {
    /// Nil lets a term fetch go on without Moodle, which only adds names and links.
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

    /// A pull does not skip the day-long cache either, so a past term's refresh adds no
    /// score-system sign-in.
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

    /// Course selection's answer for the term it serves; nil when it failed, so the transcript
    /// stands in.
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

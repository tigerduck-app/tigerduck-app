import SwiftUI
import UIKit

@Observable
final class HomeViewModel {
    private static let assignmentMutationAnimation = Animation.snappy(duration: 0.28, extraBounce: 0)

    private var prefersReducedMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    let layout = HomeLayout()
    var allCourses: [CourseStore.Course] = []
    var todayCourses: [CourseStore.Course] = []
    var assignments = HomeAssignmentList()
    var sheets = HomeSheets()
    var isEditingHome = false

    private var hasLoaded = false
    @ObservationIgnored private var storeObservation: StoreObservation?

    private var isRefreshing = false

    init() {
        storeObservation = StoreObservation(read: { _ = AppDataRevision.current }) { [weak self] in
            self?.reloadFromCache()
        }
    }

    private func reloadFromCache() {
        let courses = CanonicalCourseProvider().currentCourses()
        let all = AssignmentStore.shared.loadAssignments()
        TigerDuckTheme.ensureAssignments(courseNos: courses.map(\.courseNo), for: AccountSession.school.currentSignIn)
        allCourses = courses
        todayCourses = courses.coursesForToday()
        let currentCourseNos = Set(courses.map(\.courseNo))
        assignments.all = currentCourseNos.isEmpty ? all : all.filter { currentCourseNos.contains($0.courseNo) }
        assignments.recompute()
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true
        layout.loadSavedLayoutAddingNewSections()
        reloadFromCache()
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

    func triggerRefresh(authService: AuthService) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            await self.fetchData(authService: authService)
            await MainActor.run { [weak self] in
                self?.isRefreshing = false
            }
        }
    }

    private func fetchData(authService: AuthService) async {
        guard await SchoolRefresh.begin() else { return }
        SchoolRefresh.dropMoodleCourses()
        await authService.session.withSignIn { await SchoolRefresh.assignments(authService: authService, for: $0) }
        reloadFromCache()
        SchoolRefresh.end()
    }

    func archiveAssignment(_ assignment: AssignmentStore.Assignment) {
        withAnimation(markAnimation) { assignments.archive(assignment) }
    }

    func unarchiveAssignment(_ assignment: AssignmentStore.Assignment) {
        withAnimation(markAnimation) { assignments.unarchive(assignment) }
    }

    func markAssignmentAsLocallyCompleted(_ assignment: AssignmentStore.Assignment) {
        withAnimation(markAnimation) { assignments.markCompleted(assignment) }
    }

    func undoLocallyCompleted(_ assignment: AssignmentStore.Assignment) {
        withAnimation(markAnimation) { assignments.undoCompleted(assignment) }
    }

    private var markAnimation: Animation? {
        prefersReducedMotion ? nil : Self.assignmentMutationAnimation
    }
}

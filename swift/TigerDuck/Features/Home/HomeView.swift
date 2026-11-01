import Defaults
import SwiftUI

struct HomeView: View {
    var embedded = false

    @Environment(AppEnvironment.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.hostWindow) private var hostWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = HomeViewModel()
    @State private var showAddSection = false
    @State private var showNotImplementedAlert = false
    @State private var selectedFeature: AppFeature?
    @State private var scrollAnchor = HomeScrollAnchor()

    @State private var termTicker = MinuteTicker(interval: 60)

    private var visibleSections: [HomeSection] {
        _ = termTicker.tick
        guard !SchoolCalendar.isInSession() else { return viewModel.layout.sections }
        return viewModel.layout.sections.filter { $0.type != .todayCourses }
    }

    var body: some View {
        if embedded {
            content
                .onAppear { viewModel.load(authService: app.authService) }
        } else {
            NavigationStack { content }
                .onAppear { viewModel.load(authService: app.authService) }
        }
    }

    private var content: some View {
        let _ = AppClockState.shared.version
        return page
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.isEditingHome {
                    Button { showAddSection = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("home_add_section_title"))
                    Button(String(localized: "action_done")) { setEditing(false) }
                }
            }
        }
        .sheet(isPresented: $showAddSection) {
            AddSectionSheet(viewModel: viewModel)
                .presentationDetents([.medium])
        }
        .notImplementedAlert(isPresented: $showNotImplementedAlert)
        .syncConflictAlert(app)
        .navigationDestination(item: $selectedFeature) { feature in
            HomeFeatureDestination(feature: feature)
        }
        .navigationDestination(item: $viewModel.sheets.shownAssignment) { page in
            MoodleAssignmentView(
                store: page.store, entry: page.entry, courseName: page.courseName,
                policy: app.preferences.visualStylePolicy, accent: app.preferences.accentColor
            )
            .moodleLinkOpening()
        }
        .onChange(of: app.authService.session.currentSignIn) {
            viewModel.sheets.closeAssignment()
        }
        .onChange(of: app.router.pendingDeepLink, initial: true) { _, link in
            guard case .assignment(let id) = link else { return }
            app.router.pendingDeepLink = nil
            guard let assignment = AssignmentStore.shared.loadAssignments().first(where: { $0.assignmentId == id }) else { return }
            hostWindow.closePresentations { closedAll in openAssignment(assignment, closingSheet: closedAll) }
        }
        .sheet(item: $viewModel.sheets.selectedCourse, onDismiss: { viewModel.sheets.courseSheetDismissed() }) { course in
            let slot = viewModel.sheets.selectedCourseSlot
            CourseDetailSheet(
                course: course,
                assignments: viewModel.assignments.unfinished(for: course.courseNo),
                timeRange: slot.map { "\($0.start.timeString) - \($0.end.timeString)" },
                weekday: slot?.date.scheduleWeekday ?? AppClock.now().scheduleWeekday,
                periods: slot?.periods,
                date: slot?.date,
                slot: slot
            )
            .linkRouting()
            .onDisappear { viewModel.sheets.selectedCourseSlot = nil }
        }
        // Leaving Home, by tab, by push or by going to the background, ends editing as Done does.
        .onDisappear { setEditing(false, keepingPlace: false) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { setEditing(false, keepingPlace: false) }
        }
    }

    /// Browsing is one List, so each assignment row takes the system's `.swipeActions`
    /// (UpcomingAssignmentsView says why); editing is `HomeEditPage`. The page that opens scrolls
    /// to the section the other one showed.
    private var page: some View {
        ScrollViewReader { proxy in
            if viewModel.isEditingHome {
                editingPage
                    .onAppear { restoreScroll(proxy) }
            } else {
                HomeBrowsePage(
                    viewModel: viewModel,
                    sections: visibleSections,
                    scrollAnchor: scrollAnchor,
                    onEdit: { setEditing(true) },
                    onFeatureTap: { feature in
                        if feature.isImplemented {
                            selectedFeature = feature
                        } else {
                            showNotImplementedAlert = true
                        }
                    },
                    onOpenAssignment: { openAssignment($0) }
                )
                    .onAppear { restoreScroll(proxy) }
            }
        }
    }

    private var editingPage: some View {
        HomeEditPage(viewModel: viewModel, sections: visibleSections, scrollAnchor: scrollAnchor) {
            HomeTitleBar(controls: .spaceOnly) { setEditing(true) }
                .padding(.top, TigerDuckTheme.Spacing.md)
        }
    }

    private func setEditing(_ isEditing: Bool, keepingPlace: Bool = true) {
        guard viewModel.isEditingHome != isEditing else { return }
        if keepingPlace {
            scrollAnchor.keepPlace(in: visibleSections.map(\.id))
        } else {
            scrollAnchor.forgetPlace()
        }
        withAnimation(reduceMotion ? nil : .smoothSpring) { viewModel.isEditingHome = isEditing }
    }

    private func restoreScroll(_ proxy: ScrollViewProxy) {
        guard let target = scrollAnchor.takeTarget(in: visibleSections.map(\.id)) else { return }
        // The page's rows are laid out once the update that made it appear has finished.
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    private func openAssignment(_ assignment: AssignmentStore.Assignment, closingSheet: Bool = true) {
        if let context = MoodleCacheContext.signedIn(app.authService, for: app.authService.session.currentSignIn),
           let store = MoodleCourseStore.forAssignment(assignment.assignmentId, context: context),
           let entry = store.assignments.entry(for: assignment) {
            viewModel.sheets.show(
                MoodleAssignmentPage(entry: entry, store: store, courseName: assignment.displayCourseName),
                closingSheet: closingSheet
            )
        } else if let url = assignment.moodleDeepLink {
            let web = assignment.moodleWebURL
            Task { await openURL(url, fallback: web) }
        }
    }
}

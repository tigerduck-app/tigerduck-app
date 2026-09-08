import Defaults
import SwiftUI

struct ClassTableView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = ClassTableViewModel()

    var body: some View {
        if embedded {
            content
                .onAppear {
                    viewModel.load(authService: appState.authService)
                    viewModel.refreshMissingClassrooms()
                    viewModel.onSyncCourseOverride = { appState.syncCourseOverride(moodleCourseId: $0, colorHex: $1, customName: $2, locale: $3) }
                    viewModel.onCoursesChanged = { appState.uploadCourses($0, semester: $1) }
                    viewModel.onCourseAdded = { appState.uploadCourses($0, semester: $1, forceKeys: ["client:\($1):\($2)"]) }
                    viewModel.onCourseDeleted = { appState.deleteBackendCourse(courseNo: $0, semester: $1) }
                    viewModel.onResetBackendCourses = { await appState.deleteBackendCourses(semester: $0) }
                    Task { await viewModel.warmCachesIfNeeded(authService: appState.authService) }
                }
                .onChange(of: viewModel.currentSemester) { _, _ in
                    Task { await viewModel.refreshSelectedSemester(authService: appState.authService) }
                }
        } else {
            NavigationStack { content }
                .onAppear {
                    viewModel.load(authService: appState.authService)
                    viewModel.refreshMissingClassrooms()
                    viewModel.onSyncCourseOverride = { appState.syncCourseOverride(moodleCourseId: $0, colorHex: $1, customName: $2, locale: $3) }
                    viewModel.onCoursesChanged = { appState.uploadCourses($0, semester: $1) }
                    viewModel.onCourseAdded = { appState.uploadCourses($0, semester: $1, forceKeys: ["client:\($1):\($2)"]) }
                    viewModel.onCourseDeleted = { appState.deleteBackendCourse(courseNo: $0, semester: $1) }
                    viewModel.onResetBackendCourses = { await appState.deleteBackendCourses(semester: $0) }
                    Task { await viewModel.warmCachesIfNeeded(authService: appState.authService) }
                }
                .onChange(of: viewModel.currentSemester) { _, _ in
                    Task { await viewModel.refreshSelectedSemester(authService: appState.authService) }
                }
        }
    }

    private var content: some View {
        ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    titleBar

                    if let reauthError = appState.ntustReauthErrorMessage {
                        NTUSTReauthErrorBanner(
                            message: reauthError,
                            onRetry: {
                                appState.clearNTUSTReauthError()
                                appState.presentNTUSTLogin()
                            },
                            onDismiss: { appState.clearNTUSTReauthError() }
                        )
                    }

                    switch pageAccessState {
                    case .loginRequired:
                        LoginRequiredView(
                            layout: .page,
                            title: String(localized: "common_not_signed_in"),
                            message: String(localized: "class_table_sign_in_required_message"),
                            onPrimary: { appState.presentNTUSTLogin() }
                        )
                    case .empty:
                        // Keep the semester picker visible so the user can
                        // switch to a semester that does have courses even
                        // when the current semester's roster is empty.
                        VStack(spacing: TigerDuckTheme.Spacing.lg) {
                            if !viewModel.todayCourses.isEmpty {
                                todayCoursesSection
                            }
                            semesterPickerBar
                            EmptyStateView(
                                icon: "book.closed",
                                title: String(localized: "home_time_slider_no_courses"),
                                message: String(localized: "class_table_empty_message")
                            )
                            .padding(.vertical, TigerDuckTheme.Spacing.xxl)
                        }
                    case .content:
                        authenticatedContent
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                viewModel.triggerRefresh(authService: appState.authService)
                if Defaults[.cloudSyncEnabled] {
                    Task { await appState.syncOverridesFromBackend() }
                }
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(item: $viewModel.selectedCourse) { course in
                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                    timeRange: viewModel.selectedCourseTimeRange,
                    weekday: viewModel.selectedWeekday
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $viewModel.showAddCourse) {
                AddCourseSheet(
                    semester: viewModel.currentSemester,
                    existingCourseNos: Set(viewModel.courses.map(\.courseNo)),
                    onAdd: { viewModel.addCourse($0) },
                    onRemove: { courseNo in
                        // AddCourseSheet only invokes onRemove for courses// added in this session, so route through the
                        // user-added-only path. Using deleteCourse here
                        // would tombstone the courseNo in deletedCourseNos
                        // and later hide any real enrolled course sharing
                        // the same code from cache/network merges.
                        viewModel.removeUserAddedCourse(courseNo: courseNo)
                    }
                )
                .presentationDetents([.medium, .large])
                // The conflict alert lives on the sheet's content, not the
                // parent — when it lived on the parent, iOS dismissed the
                // sheet to present the alert (only one presentation at a
                // time per host view). Anchoring it here lets the alert
                // surface above the search results without exiting search.
                .alert(
                    String(localized: "class_table_conflict_add_failed_title"),
                    isPresented: Binding(
                        get: { viewModel.tripleConflictError != nil },
                        set: { if !$0 { viewModel.tripleConflictError = nil } }
                    ),
                    presenting: viewModel.tripleConflictError
                ) { _ in
                    Button(String(localized: "action_confirm"), role: .cancel) {
                        viewModel.tripleConflictError = nil
                    }
                } message: { err in
                    Text(String(
                        format: String(localized: "class_table_conflict_add_failed_message"),
                        err.newCourseName,
                        "\(err.weekday)",
                        err.periodId,
                        err.existingA.displayName,
                        err.existingB.displayName
                    ))
                }
            }
            .alert(String(localized: "class_table_rename_title"), isPresented: $viewModel.showRenameAlert) {
                TextField(String(localized: "class_table_course_name"), text: $viewModel.renameText)
                Button(String(localized: "action_confirm")) {
                    viewModel.confirmRename()
                }
                if let course = viewModel.courseToRename, course.customName != nil {
                    Button(String(localized: "class_table_rename_revert"), role: .destructive) {
                        viewModel.revertRename(course)
                    }
                }
                Button(String(localized: "action_cancel"), role: .cancel) {
                    viewModel.courseToRename = nil
                }
            } message: {
                if let course = viewModel.courseToRename {
                    Text(String(format: String(localized: "class_table_rename_default_label"), course.courseName))
                }
            }
            .alert(
                String(
                    format: String(localized: "class_table_reset_title_with_semester"),
                    viewModel.displayLabel(for: viewModel.currentSemester)
                ),
                isPresented: $viewModel.showResetConfirm
            ) {
                Button(String(localized: "action_confirm"), role: .destructive) {
                    viewModel.resetCourses(authService: appState.authService)
                }
                Button(String(localized: "action_cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "class_table_reset_message"))
            }
            .alert(
                String(
                    format: String(localized: "class_table_reset_title_with_semester"),
                    viewModel.displayLabel(for: viewModel.currentSemester)
                ),
                isPresented: $viewModel.showResetFailedAlert
            ) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
            } message: {
                Text(String(localized: "error_network_unavailable"))
            }
            .sheet(item: $viewModel.courseToRecolor) { course in
                CourseColorPickerSheet(
                    course: course,
                    onSelect: { viewModel.setColor(hex: $0, for: course) }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $viewModel.conflictPickerTarget) { target in
                ConflictCoursePickerSheet(
                    courses: target.courses,
                    onPick: { viewModel.pickFromConflict($0) }
                )
                .presentationDetents([.medium])
            }
    }

    /// Page-level access gate for the Class Table screen. Delegates to the
    /// canonical ``AppState/ntustProtectedAccessState(isEmpty:)`` so the
    /// cached-first rule stays consistent with Home — a returning user
    /// with stored credentials and an expired cookie sees cached data (or
    /// an empty-state placeholder), never the interactive login prompt.
    private var pageAccessState: NTUSTProtectedAccessState {
        appState.ntustProtectedAccessState(isEmpty: viewModel.courses.isEmpty)
    }

    private var titleBar: some View {
        HStack {
            Text(String(localized: "feature_class_table"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if pageAccessState != .loginRequired {
                HStack(spacing: TigerDuckTheme.Spacing.lg) {
                    SyncStatusDot(servers: [.moodle, .courseSelection, .backend])
                    headerActions
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    /// Matches `SyncStatusDot`'s own 28pt mark, so the three controls in
    /// this row sit on one line instead of stepping up in size toward the
    /// edge of the screen.
    private static let headerActionHeight: CGFloat = 28
    /// Wider than it is tall: the extra width is what turns two adjacent
    /// cells into a capsule rather than a circle, and it is where the glyphs
    /// get their breathing room now that the height is pinned.
    private static let headerActionWidth: CGFloat = 40

    /// Reset and add, sharing one Liquid Glass capsule.
    ///
    /// One backing rather than two circles: they are a set — both act on the
    /// timetable directly below — and two separate circles read as two
    /// unrelated controls that happen to be adjacent. This is also what the
    /// system does with a toolbar item group on iOS 26, which is the shape
    /// users are learning to read as "these belong together".
    ///
    /// The status dot stays outside it deliberately. It reports on the
    /// servers, it does not act on the timetable, and folding it in would
    /// claim a relationship that isn't there.
    ///
    /// Sits in the page's own header row rather than a toolbar, so nothing
    /// supplies a backing unless we do — and a bare glyph over a dense
    /// timetable reads as part of the grid instead of a control acting on it.
    @ViewBuilder
    private var headerActions: some View {
        let row = HStack(spacing: 0) {
            Button {
                viewModel.showResetConfirm = true
            } label: {
                headerIcon("arrow.triangle.2.circlepath")
            }
            .accessibilityLabel(Text("class_table_reset_title"))
            Button {
                viewModel.showAddCourse = true
            } label: {
                headerIcon("plus")
            }
            .accessibilityLabel(Text("add_course_title"))
        }
        if #available(iOS 26, *) {
            row.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            row
        }
    }

    /// `contentShape` is explicit because the glyph is smaller than its
    /// cell: without it the tappable area is the symbol's own bounds, and
    /// the padding that makes the capsule look right would not be tappable.
    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .frame(width: Self.headerActionWidth, height: Self.headerActionHeight)
            .contentShape(.rect)
    }

    private var authenticatedContent: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            if !viewModel.todayCourses.isEmpty {
                todayCoursesSection
            }
            semesterPickerBar

            TimetableGridView(viewModel: viewModel)
        }
    }

    private var todayCoursesSection: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: String(localized: "home_section_today_courses"))
            TodayCourseCarousel(
                courses: viewModel.todayCourses,
                hasAssignment: viewModel.hasAssignment,
                showProgress: false,
                ongoing: viewModel.ongoingCourses,
                onSelect: { course in
                    // Carousel only ever surfaces today's courses, so pin
                    // the sheet's weekday context to today. Without this
                    // `selectedCourseTimeRange` stays nil and the time
                    // card collapses to `—`. Set weekday before course so
                    // the sheet's first read sees both populated. Clear
                    // the block-time override too — a prior Current-class
                    // tap could otherwise leak its block range into the
                    // sheet for an unrelated today card.
                    viewModel.selectedCourseBlockTimeRange = nil
                    viewModel.selectedPeriodId = nil
                    viewModel.selectedWeekday = AppClock.now().scheduleWeekday
                    viewModel.selectedCourse = course
                },
                onSelectOngoing: { info in
                    viewModel.selectOngoing(info)
                }
            )
        }
    }

    /// Semester picker + credit total row. Extracted so it can be shown
    /// even when the current semester has no courses — otherwise the user
    /// has no way to pivot to a semester that does have data.
    private var semesterPickerBar: some View {
        HStack {
            Picker(String(localized: "class_table_semester_picker_label"), selection: $viewModel.currentSemester) {
                ForEach(viewModel.availableSemesters, id: \.self) { code in
                    Text(viewModel.displayLabel(for: code)).tag(code)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()

            Text(creditsLabel)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(.horizontal)
    }

    /// "B11315000 · 20 credits": the student id leads so a shared screen
    /// shows whose timetable this is; both halves keep the secondary tint.
    private var creditsLabel: String {
        let credits = String(format: String(localized: "class_table_total_credits_value"), viewModel.totalCredits)
        guard let studentId = appState.authService.storedStudentId, !studentId.isEmpty else { return credits }
        return "\(studentId) · \(credits)"
    }
}

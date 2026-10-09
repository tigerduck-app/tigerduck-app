import Defaults
import SwiftUI

struct ClassTableView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = ClassTableViewModel(
        isClassDay: { AcademicCalendarStore.shared.isClassDay($0) }
    )
    @State private var exportedFile: ExportedFile?
    @State private var showExportFailed = false
    @State private var isExporting = false
    // Read here and passed on to the export, whose renderer does not inherit
    // this view's environment.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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
                    viewModel.onResetBackendCourses = { await appState.deleteBackendCourses(semester: $0, thenLocally: $1) }
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
                    viewModel.onResetBackendCourses = { await appState.deleteBackendCourses(semester: $0, thenLocally: $1) }
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
                        // onRemove fires only for courses added this session. `deleteCourse`
                        // would tombstone the courseNo, hiding any real enrolled course with
                        // the same code from cache and network merges.
                        viewModel.removeUserAddedCourse(courseNo: courseNo)
                    }
                )
                .presentationDetents([.medium, .large])
                // The conflict alert hangs off the sheet's content: on the parent, iOS
                // would dismiss the sheet to present it (one presentation per host
                // view). Here it shows above the search results without leaving search.
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
            .sheet(item: $exportedFile) { file in
                ShareSheet(url: file.url)
                    .onDisappear { ClassTableExporter.discard(file.url) }
                    // The heights UIKit gives the share sheet when it
                    // presents one itself.
                    .presentationDetents([.medium, .large])
            }
            .alert(String(localized: "class_table_export_failed"), isPresented: $showExportFailed) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
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

    /// Below iOS 26 this matches the Calendar "Today" button (40.33pt, a padded
    /// `.bordered` from `GlassTextButtonModifier`), so both pages' header controls
    /// are one size. On 26 it does not match Today's 28.33pt `.buttonStyle(.glass)`:
    /// glass that short behind an icon reads as a sliver, not a button. 36pt, about
    /// 1.3x, reads as a control and stays close to the pre-26 40pt.
    ///
    /// `HeaderControlMetricsTests` measures both against the live Today button,
    /// so it catches Apple changing those metrics.
    private static var headerActionHeight: CGFloat {
        if #available(iOS 26, *) { 36 } else { 40 }
    }

    /// Every action on the timetable, behind one ⋯ button like a mail message's.
    /// A menu names each action; unlabelled glyphs could not say "export".
    ///
    /// The status dot stays outside: it reports on the servers and does not act
    /// on the timetable.
    ///
    /// The page's header row, unlike a toolbar, supplies no backing, and a bare
    /// glyph over the dense timetable reads as part of the grid, not a control.
    @ViewBuilder
    private var headerActions: some View {
        let menu = Menu {
            Section {
                Button {
                    viewModel.showAddCourse = true
                } label: {
                    Label(String(localized: "add_course_title"), systemImage: "plus")
                }
                Button {
                    viewModel.showResetConfirm = true
                } label: {
                    Label(String(localized: "class_table_reset_title"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Section {
                Button {
                    exportScreenshot()
                } label: {
                    Label(String(localized: "class_table_export_screenshot"), systemImage: "square.and.arrow.up")
                }
                // Only the content state draws a grid; anything else would
                // export a header over nothing. Held off while an export is
                // still being written, so two cannot race for the same file.
                .disabled(pageAccessState != .content || isExporting)
            }
        } label: {
            headerIcon("ellipsis")
        }
        .accessibilityLabel(Text("class_table_more_actions"))
        if #available(iOS 26, *) {
            menu.glassEffect(.regular.interactive(), in: .circle)
        } else {
            // Below 26 no glass supplies a backing, and a bare glyph reads as
            // unfinished beside Today's filled pill. `.secondarySystemFill` is what
            // `.bordered`, Today's pre-26 style, fills with.
            menu.background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
    }

    /// `contentShape` is explicit because the glyph is smaller than its cell:
    /// without it only the symbol's bounds are tappable, not the padding that
    /// makes the circle look right.
    ///
    /// `.subheadline`, not `.body`: Today's caption label is 14.33pt tall in its
    /// 28.33pt pill, while a `.body` symbol is 17pt and looks heavier even at the
    /// same outer height. `.subheadline` gives 15.33pt, the same optical weight,
    /// and as a semantic font it scales with Dynamic Type like Today's label.
    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .frame(width: Self.headerActionHeight, height: Self.headerActionHeight)
            .contentShape(.rect)
    }

    /// Renders the timetable to a PNG and hands it to the share sheet, where
    /// Save Image, Save to Files and every sharing target are on offer.
    private func exportScreenshot() {
        isExporting = true
        Task {
            let url = await ClassTableExporter.render(
                viewModel: viewModel,
                appState: appState,
                dynamicTypeSize: dynamicTypeSize,
                layoutDirection: layoutDirection,
                legibilityWeight: legibilityWeight,
                differentiateWithoutColor: differentiateWithoutColor
            )
            isExporting = false
            if let url {
                exportedFile = ExportedFile(url: url)
            } else {
                showExportFailed = true
            }
        }
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
                    // The carousel shows only today's courses: pin the weekday to today
                    // or the time card shows a dash, set it before the course for the
                    // sheet's first read, and clear any block range a Current-class tap left.
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
        let credits = String(format: String(localized: "class_table_total_credits_value"), viewModel.totalCredits.creditsText)
        guard let studentId = appState.authService.storedStudentId, !studentId.isEmpty else { return credits }
        return "\(studentId) · \(credits)"
    }
}

/// An exported class table image waiting for the share sheet.
private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

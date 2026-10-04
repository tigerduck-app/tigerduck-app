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
            .sheet(item: $exportedFile) { file in
                ShareSheet(url: file.url)
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

    /// Runtime-dependent, because the reference differs per OS.
    ///
    /// Below 26 this tracks the Calendar "Today" button, which renders
    /// 40.33pt there — a padded `.bordered` from `GlassTextButtonModifier`.
    /// Matching it is what keeps the two pages' header controls the same
    /// size on that OS.
    ///
    /// On 26 Today is only 28.33pt, because `.buttonStyle(.glass)` is a much
    /// tighter control. Deliberately not matched: at Today's height the
    /// glass behind an icon reads as a thin sliver rather than a button.
    /// 36pt is ~1.3x that, enough glass to read as a control in its own
    /// right — and close to the 40pt the pre-26 path already uses, so the
    /// two OSes end up more alike than the underlying button styles are.
    ///
    /// `HeaderControlMetricsTests` measures both against the live Today
    /// button, so it still catches Apple moving those metrics underneath us.
    private static var headerActionHeight: CGFloat {
        if #available(iOS 26, *) { 36 } else { 40 }
    }

    /// Everything that acts on the timetable, behind one ⋯ button — the
    /// same shape as a mail message's actions.
    ///
    /// Add and reset used to sit here as a pair of glyphs. A third action
    /// would have made a row of three unlabelled icons, and export is not
    /// something a glyph alone can say; a menu names each one.
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
            // Below 26 there is no glass to supply a backing, and a bare
            // glyph beside Today's filled pill reads as unfinished rather
            // than as the same class of control. `.secondarySystemFill` is
            // what `.bordered` — Today's own pre-26 style — fills with.
            menu.background(Circle().fill(Color(uiColor: .secondarySystemFill)))
        }
    }

    /// `contentShape` is explicit because the glyph is smaller than its
    /// cell: without it the tappable area is the symbol's own bounds, and
    /// the padding that makes the circle look right would not be tappable.
    /// `.subheadline` rather than `.body`: Today's caption label renders
    /// 14.33pt tall inside its 28.33pt pill, where a `.body` symbol is a
    /// full 17pt. Matching the outer height alone still left the icon
    /// visibly heavier than the button it sits next to a tab away —
    /// `.subheadline` puts the glyph at 15.33pt, the same optical weight.
    /// A semantic font, not a fixed size, so it scales with Dynamic Type
    /// the way Today's label does.
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
                legibilityWeight: legibilityWeight
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

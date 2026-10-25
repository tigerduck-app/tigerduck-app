import Defaults
import SwiftUI

struct ClassTableView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.requestClassTableImport) private var requestImport
    @Environment(\.isUpdatingImportedClassTable) private var isUpdatingImport
    @State private var viewModel = ClassTableViewModel(
        isClassDay: { AcademicCalendarStore.shared.isClassDay($0) }
    )
    @State private var exportedFile: ExportedFile?
    @State private var showExportFailed = false
    @State private var isExporting = false
    @State private var shareModel: ClassTableShareModel?
    @State private var shareAvailability = ClassTableShareModel.AvailabilityMemo()
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scroll = ScrollState()
    @State private var tableSwitches = 0
    @Default(.pinTodayCoursesOnClassTable) private var pinsTodayCourses
    // Read here and passed on to the export, whose renderer does not inherit
    // this view's environment.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        if embedded {
            content
                .onAppear {
                    viewModel.load(authService: appState.authService)
                    viewModel.refreshMissingClassrooms(authService: appState.authService)
                    viewModel.onSyncCourseOverride = { appState.syncCourseOverride(moodleCourseId: $0, colorHex: $1, customName: $2, locale: $3) }
                    viewModel.onSyncColorPick = { appState.syncColorPick($0, for: $1, changed: $2) }
                    viewModel.onSyncCourseIgnore = {
                        appState.syncCourseIgnore(semester: $1, courseNo: $0.courseNo, moodleIdNumber: $0.moodleIdNumber, ignore: $2)
                    }
                    viewModel.onCoursesChanged = { appState.uploadCourses($0, semester: $1) }
                    viewModel.onCourseAdded = {
                        appState.uploadCourses($0, semester: $1, forceKeys: [CourseTombstone.serverKey(semester: $1, courseNo: $2)])
                    }
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
                    viewModel.refreshMissingClassrooms(authService: appState.authService)
                    viewModel.onSyncCourseOverride = { appState.syncCourseOverride(moodleCourseId: $0, colorHex: $1, customName: $2, locale: $3) }
                    viewModel.onSyncColorPick = { appState.syncColorPick($0, for: $1, changed: $2) }
                    viewModel.onSyncCourseIgnore = {
                        appState.syncCourseIgnore(semester: $1, courseNo: $0.courseNo, moodleIdNumber: $0.moodleIdNumber, ignore: $2)
                    }
                    viewModel.onCoursesChanged = { appState.uploadCourses($0, semester: $1) }
                    viewModel.onCourseAdded = {
                        appState.uploadCourses($0, semester: $1, forceKeys: [CourseTombstone.serverKey(semester: $1, courseNo: $2)])
                    }
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
                        VStack(spacing: TigerDuckTheme.Spacing.lg) {
                            if pinsTodayCourses, !viewModel.todayCourses.isEmpty {
                                todayCoursesSection
                            }
                            semesterPickerBar
                            EmptyStateView(
                                icon: "book.closed",
                                title: String(localized: "home_time_slider_no_courses"),
                                message: viewModel.shownPerson == nil
                                    ? String(localized: "class_table_empty_message")
                                    : String(localized: "class_table_import_lookup_failed")
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
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geometry in
                scroll.geometry = geometry
            }
            .refreshable {
                guard viewModel.shownPerson == nil else {
                    await viewModel.refreshShownPerson()
                    return
                }
                viewModel.triggerRefresh(authService: appState.authService)
                if Defaults[.cloudSyncEnabled] {
                    Task { await appState.syncOverridesFromBackend() }
                }
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .onChange(of: viewModel.shownTable) { _, _ in
                tableSwitches += 1
                viewModel.showShownTable()
            }
            .onChange(of: appState.authService.loginGeneration) { _, _ in
                viewModel.closeOwnEdits()
            }
            .sheet(item: $viewModel.selectedCourse) { course in
                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                    timeRange: viewModel.selectedCourseTimeRange,
                    weekday: viewModel.selectedWeekday,
                    periods: viewModel.selectedCoursePeriods,
                    showsMoodle: viewModel.shownPerson == nil
                )
            }
            .sheet(isPresented: $viewModel.showAddCourse) {
                AddCourseSheet(
                    semester: viewModel.currentSemester,
                    tableCourses: viewModel.courses,
                    onAdd: { viewModel.addCourse($0) },
                    onRemove: { courseNo in
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
                        AppConstants.Periods.shortWeekdayLabel(err.weekday),
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
                let authService = appState.authService
                let generation = authService.loginGeneration
                CourseColorPickerSheet(
                    course: course,
                    isCurrent: { authService.loginGeneration == generation },
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
            .alert(String(localized: "class_table_rename_title"), isPresented: $viewModel.isRenamingPerson) {
                TextField(String(localized: "class_table_nickname"), text: $viewModel.nicknameDraft)
                Button(String(localized: "action_save")) {
                    viewModel.saveNickname()
                }
                .disabled(!viewModel.canSaveNickname)
                Button(String(localized: "action_cancel"), role: .cancel) {}
            }
            .alert(
                String(
                    format: String(localized: "class_table_delete_user_confirm"),
                    viewModel.personInAlert?.nickname ?? ""
                ),
                isPresented: $viewModel.isDeletingPerson
            ) {
                Button(String(localized: "class_table_delete"), role: .destructive) {
                    viewModel.deletePersonInAlert()
                }
                Button(String(localized: "action_cancel"), role: .cancel) {}
            }
            .alert(String(localized: "class_table_import_lookup_failed"), isPresented: $viewModel.showsLookupFailed) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
            }
            .alert(String(localized: "bulletin_save_failed_title"), isPresented: $viewModel.showsSaveFailed) {
                Button(String(localized: "action_confirm"), role: .cancel) {}
            }
            .classTableShareSheet(model: $shareModel, loginGeneration: appState.authService.loginGeneration)
    }

    private var pageAccessState: NTUSTProtectedAccessState {
        if viewModel.shownPerson != nil { return viewModel.courses.isEmpty ? .empty : .content }
        return appState.ntustProtectedAccessState(isEmpty: viewModel.courses.isEmpty)
    }

    private var titleBar: some View {
        HStack {
            Text(String(localized: "feature_class_table"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if pageAccessState != .loginRequired {
                HStack(spacing: TigerDuckTheme.Spacing.lg) {
                    SyncStatusDot(servers: [.moodle, .courseSelection, .backend], lastSynced: .schoolData)
                    headerActions
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    private var headerActions: some View {
        HeaderMenuButton(accessibilityLabel: String(localized: "class_table_more_actions")) {
            if viewModel.shownPerson != nil {
                otherPersonActions
            } else {
                ownActions
            }
        }
    }

    @ViewBuilder
    private var ownActions: some View {
        Section {
            Button {
                viewModel.showAddCourse = true
            } label: {
                Label(String(localized: "add_course_title"), systemImage: "plus")
            }
            Button {} label: {
                Label(String(localized: "class_table_subscribe_clubs"), systemImage: "person.2")
            }
            .disabled(true)
        }
        Section {
            Button {
                openShareSheet()
            } label: {
                Label(String(localized: "class_table_share"), systemImage: "qrcode")
            }
            .disabled(isExporting || !ClassTableShareModel.canShare(
                studentId: appState.authService.storedStudentId,
                shownTerm: .init(semester: viewModel.currentSemester, courses: viewModel.courses),
                semesters: viewModel.availableSemesters,
                memo: shareAvailability
            ))
            Button {
                requestImport()
            } label: {
                Label(String(localized: "class_table_import"), systemImage: "qrcode.viewfinder")
            }
        }
        Section {
            exportButton
        }
        Section {
            Button(role: .destructive) {
                viewModel.showResetConfirm = true
            } label: {
                Label(String(localized: "class_table_reset_title"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var otherPersonActions: some View {
        ForEach(ClassTableOtherPersonAction.sections, id: \.self) { section in
            Section {
                ForEach(section, id: \.self) { action in
                    if action == .exportScreenshot {
                        exportButton
                    } else {
                        Button(role: action.role) {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            }
        }
    }

    private func perform(_ action: ClassTableOtherPersonAction) {
        switch action {
        case .exportScreenshot: exportScreenshot()
        case .importClassTable: requestImport()
        case .rename: viewModel.startRenamingPerson()
        case .deleteUser: viewModel.startDeletingPerson()
        }
    }

    private var exportButton: some View {
        Button {
            exportScreenshot()
        } label: {
            Label(String(localized: "class_table_export_screenshot"), systemImage: "square.and.arrow.up")
        }
        .disabled(pageAccessState != .content || isExporting)
    }

    private func exportScreenshot() {
        isExporting = true
        Task {
            let url = await ClassTableExporter.render(
                viewModel: viewModel,
                appState: appState,
                colorScheme: colorScheme,
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

    private func openShareSheet() {
        guard let studentId = appState.authService.storedStudentId else { return }
        let terms = ClassTableShareModel.terms(
            in: viewModel.availableSemesters,
            shownTerm: .init(semester: viewModel.currentSemester, courses: viewModel.courses)
        )
        guard !terms.isEmpty else { return }
        shareModel = ClassTableShareModel(
            studentId: studentId,
            terms: terms,
            semesterLabel: viewModel.displayLabel(for:)
        )
    }

    private var authenticatedContent: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            if pinsTodayCourses, !viewModel.todayCourses.isEmpty {
                todayCoursesSection
            }
            semesterPickerBar

            TimetableGridView(viewModel: viewModel, switchCount: tableSwitches, onSwitch: keepRowsInPlace)
        }
    }

    private func keepRowsInPlace(before: TimetableRowTops, after: TimetableRowTops) {
        guard let geometry = scroll.geometry else { return }
        let top = geometry.contentInsets.top
        guard geometry.contentOffset.y + top > 0 else { return }
        let shift = TimetableRowTops.shift(from: before, to: after, visibleTop: top)
        guard shift != 0 else { return }
        // `scrollTo(y:)` counts from the top inset, which `contentOffset` does not.
        scrollPosition.scrollTo(y: max(0, geometry.contentOffset.y + top + shift))
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
                    viewModel.selectedCoursePeriods = nil
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

            ownerLabel
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var ownerLabel: some View {
        if viewModel.importedTables.hasImportedClassTables {
            Menu {
                ClassTableSwitcherMenuItems(
                    store: viewModel.importedTables,
                    userName: ClassTableSwitcherEntry.userName(studentId: appState.authService.storedStudentId)
                )
            } label: {
                HStack(spacing: TigerDuckTheme.Spacing.xs) {
                    Text(creditsLabel)
                    if isUpdatingImport {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                }
                .font(TigerDuckTheme.Typography.body)
            }
            .menuOrder(.fixed)
            .accessibilityLabel(Text("a11y_class_table_switch"))
            .accessibilityValue(Text(creditsLabel))
        } else {
            Text(creditsLabel)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var creditsLabel: String {
        let credits = String(format: String(localized: "class_table_total_credits_value"), viewModel.totalCredits.creditsText)
        let owner = viewModel.shownPerson?.nickname ?? appState.authService.storedStudentId
        guard let owner, !owner.isEmpty else { return credits }
        return "\(owner) · \(credits)"
    }
}

private final class ScrollState {
    var geometry: ScrollGeometry?
}

private struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

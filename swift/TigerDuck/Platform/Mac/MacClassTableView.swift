#if os(macOS)
import SwiftUI
import TigerDuckCore

struct MacClassTableView: View {
    @Environment(AppEnvironment.self) private var app

    @State private var viewModel = ClassTableViewModel()
    @State private var detailMoodlePath: [MoodleCourseRoute] = []
    @State private var shareModel: ClassTableShareModel?
    @State private var shareAvailability = ClassTableShareModel.AvailabilityMemo()
    @State private var importModel: ClassTableImportModel?
    @State private var showImportPicker = false
    @State private var isLoadingSemester = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if viewModel.courses.isEmpty {
                    if isLoadingSemester {
                        loadingState
                    } else {
                        emptyState
                    }
                } else {
                    MacClassTableGrid(viewModel: viewModel)
                }
            }
            .macReadableContent(maxWidth: MacContentWidth.wide)
        }
        .toolbar {
            MacClassTableToolbar(
                viewModel: viewModel, importModel: importModel, studentId: app.authService.storedStudentId,
                shareAvailability: shareAvailability, share: openShareSheet, requestImport: requestImport
            )
        }
        .modifier(MacClassTableImport(model: $importModel, showsPicker: $showImportPicker, request: requestImport))
        .classTableShareSheet(model: $shareModel, signIn: app.authService.session.currentSignIn)
        .modifier(ClassTableCourseEditDialogs(viewModel: viewModel, editor: viewModel.editor))
        .modifier(ClassTablePersonDialogs(people: viewModel.people))
        .task {
            viewModel.editor.sync = .live(app)
            viewModel.loader.load()
            await viewModel.loader.warmCachesIfNeeded(authService: app.authService)
            await ensureSemesterFetched()
        }
        .onChange(of: viewModel.currentSemester) {
            Task { await ensureSemesterFetched() }
        }
        .onChange(of: viewModel.shownTable) {
            viewModel.showShownTable()
        }
        // Course detail uses a custom overlay (not `.sheet`) so the user can
        // dismiss by clicking the backdrop — macOS sheets are window-modal
        // and swallow all outside clicks, leaving ESC as the only escape.
        .overlay {
            if viewModel.selection.course != nil {
                MacCourseDetailOverlay(viewModel: viewModel, moodlePath: $detailMoodlePath)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectionID)
        .onChange(of: selectionID) { detailMoodlePath = [] }
        .preference(key: MacRefreshShortcutClaimKey.self, value: detailMoodlePath.last?.refreshesOnItsOwn ?? false)
    }

    private var selectionID: String? {
        let selection = viewModel.selection
        guard let course = selection.course else { return nil }
        return "\(course.courseNo)-\(selection.weekday ?? 0)-\(selection.periodId ?? "")"
    }

    private func ensureSemesterFetched() async {
        let target = viewModel.currentSemester
        guard viewModel.shownPerson == nil, viewModel.courseStore.loadCourses(semester: target).isEmpty else { return }
        isLoadingSemester = true
        await viewModel.loader.refreshSelectedSemester(authService: app.authService)
        if viewModel.currentSemester == target {
            isLoadingSemester = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "feature_class_table"))
                    .font(.largeTitle.bold())
                Text(String(
                    format: String(localized: "desktop_class_table_subtitle_value"),
                    viewModel.displayLabel(for: viewModel.currentSemester),
                    viewModel.courses.count,
                    viewModel.grid.totalCredits.creditsText
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switcher
        }
    }

    @ViewBuilder
    private var switcher: some View {
        let store = viewModel.people.store
        if store.hasImportedClassTables {
            let userName = ClassTableSwitcherEntry.userName(studentId: app.authService.storedStudentId)
            let name = viewModel.shownPerson?.nickname ?? userName
            Menu {
                ClassTableSwitcherMenuItems(store: store, userName: userName)
            } label: {
                Text(name)
            }
            .menuOrder(.fixed)
            .fixedSize()
            .accessibilityLabel(Text("a11y_class_table_switch"))
            .accessibilityValue(Text(name))
        }
    }

    private func requestImport() {
        guard importModel?.isLookingUp != true, importModel?.isReadingImage != true else { return }
        showImportPicker = true
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(String(localized: "desktop_class_table_empty_title"))
                .font(.headline)
            Text(String(localized: "desktop_class_table_empty_hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(String(
                format: String(localized: "desktop_class_table_loading_value"),
                viewModel.displayLabel(for: viewModel.currentSemester)
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func openShareSheet() {
        guard let studentId = app.authService.storedStudentId else { return }
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
}
#endif

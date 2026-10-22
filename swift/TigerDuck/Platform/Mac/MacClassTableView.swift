#if os(macOS)
import SwiftUI
import Defaults
import UniformTypeIdentifiers

struct MacClassTableView: View {
    @Environment(AppState.self) var appState

    @Default(.alwaysShowAllPeriods) private var showsAllPeriods
    @Default(.outlineRequiredCourses) var outlineRequiredCourses

    @State var selectedSemester: String = SemesterCatalog.selectedSemester(
        storedPick: Defaults[.classTableSelectedSemester]
    )
    @State private var isFollowingNewestSemester = false
    @State var selectedSlot: SelectedSlot?
    @State private var detailMoodlePath: [MoodleCourseRoute] = []
    @State private var showAddCourse: Bool = false
    @State private var shareModel: ClassTableShareModel?
    @State private var shareAvailability = ClassTableShareModel.AvailabilityMemo()
    @State private var showImportPicker = false
    @State private var importModel: ClassTableImportModel?
    @State var courseToRecolor: SDCourse?

    @State var courseToRename: SDCourse?
    @State var renameText: String = ""
    @State var showRenameAlert: Bool = false

    @State private var isRenamingPerson = false
    @State private var nicknameDraft = ""
    @State private var isDeletingPerson = false
    @State private var showsSaveFailed = false
    @State private var personInAlert: ImportedPerson?

    struct SelectedSlot: Identifiable {
        let course: SDCourse
        let weekday: Int
        let periodId: String
        var id: String { "\(course.courseNo)-\(weekday)-\(periodId)" }
    }
    @State var cacheRevision: Int = 0
    @State private var coursesMemo = ViewMemo<CoursesKey, [SDCourse]>()

    private struct CoursesKey: Equatable {
        let semester: String
        let revision: Int
    }
    @State private var ignoredCoursesMemo = ViewMemo<Int, Set<String>>()

    var ignoredAssignmentCourses: Set<String> {
        guard shownPerson == nil else { return [] }
        return ignoredCoursesMemo.value(for: cacheRevision) { DataCache.shared.loadIgnoredAssignmentCourses() }
    }

    var shownPerson: ImportedPerson? { ImportedClassTableStore.shared.shownPerson }
    @State private var hasWarmedCaches = false
    @State private var isLoadingSemester = false
    @State var tripleConflictError: TripleConflictError?

    struct TripleConflictError: Identifiable {
        let id = UUID()
        let weekday: Int
        let periodId: String
        let newCourseName: String
        let existingA: SDCourse
        let existingB: SDCourse
    }

    var weekdays: [Int] {
        let occupied = Set(courses.flatMap { $0.schedule.keys })
        var days = Array(1...5)
        if occupied.contains(6) { days.append(6) }
        if occupied.contains(7) { days.append(7) }
        return days
    }

    let cellHeight: CGFloat = 56
    let rowSpacing: CGFloat = 4
    let periodLabelWidth: CGFloat = 56

    private var availableSemesters: [String] {
        if let shownPerson { return shownPerson.semesters }
        let options = SemesterCatalog.availableSemesters()
        return options.contains(selectedSemester) ? options : options + [selectedSemester]
    }

    var courses: [SDCourse] {
        let semester = selectedSemester
        if let shownPerson { return shownPerson.courses(in: semester) }
        return coursesMemo.value(for: CoursesKey(semester: semester, revision: cacheRevision)) {
            CanonicalCourseProvider.merge(
                primary: DataCache.shared.loadCourses(semester: semester),
                userAdded: DataCache.shared.loadUserAddedCourses(semester: semester),
                semester: semester,
                deletedCourseNos: Set(DataCache.shared.loadDeletedCourseNos()),
                customNames: DataCache.shared.loadCourseCustomNamesFlat()
            )
        }
    }

    var visiblePeriods: [String] {
        guard !showsAllPeriods else {
            return AppConstants.Periods.chronologicalOrder
        }
        let occupied = Set(courses.flatMap { $0.schedule.values.flatMap { $0 } })
        return AppConstants.Periods.chronologicalOrder.filter {
            AppConstants.Periods.defaultVisible.contains($0) || occupied.contains($0)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if courses.isEmpty {
                    if isLoadingSemester {
                        loadingState
                    } else {
                        emptyState
                    }
                } else {
                    glassGridCard
                }
            }
            .macReadableContent(maxWidth: MacContentWidth.wide)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker(String(localized: "class_table_semester_picker_label"), selection: $selectedSemester) {
                    ForEach(availableSemesters, id: \.self) { code in
                        Text(displayLabel(for: code)).tag(code)
                    }
                }
                .pickerStyle(.menu)
            }
            if shownPerson != nil {
                ToolbarItem(placement: .automatic) {
                    otherPersonActions
                }
            } else {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showAddCourse = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text(String(localized: "add_course_title"))
                        }
                        .fixedSize()
                    }
                    .help(String(localized: "add_course_title"))
                }
            }
            if ImportedClassTableStore.shared.shownPerson == nil {
                ToolbarItem(placement: .automatic) {
                    Button {
                        openShareSheet()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "qrcode")
                            Text(String(localized: "class_table_share"))
                        }
                        .fixedSize()
                    }
                    .help(String(localized: "class_table_share"))
                    .disabled(!ClassTableShareModel.canShare(
                        studentId: appState.authService.storedStudentId,
                        shownTerm: .init(semester: selectedSemester, courses: courses),
                        semesters: availableSemesters,
                        memo: shareAvailability
                    ))
                }
            }
            ToolbarItem(placement: .automatic) {
                if let importModel, importModel.isLookingUp, importModel.pending == nil {
                    Button {
                        importModel.cancel()
                    } label: {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "action_cancel"))
                        }
                        .fixedSize()
                    }
                    .help(String(localized: "action_cancel"))
                } else {
                    Button {
                        showImportPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "qrcode.viewfinder")
                            Text(String(localized: "class_table_import"))
                        }
                        .fixedSize()
                    }
                    .help(String(localized: "class_table_import"))
                    .disabled(importModel?.isLookingUp == true || importModel?.isReadingImage == true)
                }
            }
        }
        .environment(\.requestClassTableImport, requestImport)
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.image]) { result in
            let model = ClassTableImportModel.live(authService: appState.authService)
            importModel = model
            switch result {
            case .success(let url):
                Task { await model.readImage(fileAt: url) }
            case .failure(let error):
                AppLogger.captureError(error, context: ["phase": "classTableImport.pickFile"])
                Task { await model.readImage(nil) }
            }
        }
        .classTableImportPrompts(importModel, onConfirmScreen: false)
        .sheet(item: Binding(get: { importModel?.pending }, set: { if $0 == nil { importModel?.cancel() } })) { pending in
            if let importModel {
                ClassTableImportConfirmView(model: importModel, code: pending.code)
            }
        }
        .onChange(of: importModel?.isFinished) { _, isFinished in
            if isFinished == true { importModel = nil }
        }
        .classTableShareSheet(model: $shareModel, loginGeneration: appState.authService.loginGeneration)
        .sheet(isPresented: $showAddCourse) {
            AddCourseSheet(
                semester: selectedSemester,
                existingCourseNos: Set(courses.map(\.courseNo)),
                onAdd: { addUserCourse($0) },
                onRemove: { removeUserAddedCourse(courseNo: $0) }
            )
            .alert(
                String(localized: "class_table_conflict_add_failed_title"),
                isPresented: Binding(
                    get: { tripleConflictError != nil },
                    set: { if !$0 { tripleConflictError = nil } }
                ),
                presenting: tripleConflictError
            ) { _ in
                Button(String(localized: "action_confirm"), role: .cancel) {
                    tripleConflictError = nil
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
        .sheet(item: $courseToRecolor) { course in
            let authService = appState.authService
            let generation = authService.loginGeneration
            CourseColorPickerSheet(
                course: course,
                isCurrent: { authService.loginGeneration == generation },
                onSelect: { hex in
                    let changed = TigerDuckTheme.setColor(hex: hex, for: course.courseNo)
                    cacheRevision &+= 1
                    NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
                    appState.syncColorPick(hex, for: course, changed: changed)
                }
            )
            .frame(minWidth: 360, minHeight: 480)
        }
        .alert(String(localized: "class_table_rename_title"), isPresented: $showRenameAlert) {
            TextField(String(localized: "class_table_course_name"), text: $renameText)
            Button(String(localized: "action_confirm")) {
                confirmRename()
            }
            if let course = courseToRename, course.customName != nil {
                Button(String(localized: "class_table_rename_revert"), role: .destructive) {
                    revertRename(course)
                }
            }
            Button(String(localized: "action_cancel"), role: .cancel) {
                courseToRename = nil
            }
        } message: {
            if let course = courseToRename {
                Text(String(format: String(localized: "class_table_rename_default_label"), course.courseName))
            }
        }
        .alert(String(localized: "class_table_rename_title"), isPresented: $isRenamingPerson) {
            TextField(String(localized: "class_table_nickname"), text: $nicknameDraft)
            Button(String(localized: "action_save")) {
                if let personInAlert, ImportedClassTableStore.shared.rename(personInAlert.id, to: nicknameDraft) == .failed {
                    showsSaveFailed = true
                }
            }
            .disabled(nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(String(localized: "action_cancel"), role: .cancel) {}
        }
        .alert(
            String(format: String(localized: "class_table_delete_user_confirm"), personInAlert?.nickname ?? ""),
            isPresented: $isDeletingPerson
        ) {
            Button(String(localized: "class_table_delete"), role: .destructive) {
                if let personInAlert, ImportedClassTableStore.shared.delete(personInAlert.id) == .failed {
                    showsSaveFailed = true
                }
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        }
        .alert(String(localized: "bulletin_save_failed_title"), isPresented: $showsSaveFailed) {
            Button(String(localized: "action_confirm"), role: .cancel) {}
        }
        .task {
            await warmCachesIfNeeded()
            await ensureCurrentSemesterFetched()
        }
        .onChange(of: selectedSemester) { _, newValue in
            if isFollowingNewestSemester {
                isFollowingNewestSemester = false
            } else if shownPerson == nil {
                Defaults[.classTableSelectedSemester] = newValue
            }
            Task { await ensureCurrentSemesterFetched() }
        }
        .onChange(of: ImportedClassTableStore.shared.shownTable, initial: true) { _, _ in
            if shownPerson != nil {
                showAddCourse = false
                showRenameAlert = false
                courseToRename = nil
                courseToRecolor = nil
            }
            let semester = shownPerson?.semester(keeping: selectedSemester)
                ?? SemesterCatalog.selectedSemester(storedPick: Defaults[.classTableSelectedSemester])
            guard semester != selectedSemester else { return }
            isFollowingNewestSemester = true
            selectedSemester = semester
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)) { _ in
            cacheRevision &+= 1
        }
        .overlay {
            if let slot = selectedSlot {
                courseDetailOverlay(slot: slot)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedSlot?.id)
        .onChange(of: selectedSlot?.id) { detailMoodlePath = [] }
        .preference(key: MacRefreshShortcutClaimKey.self, value: detailMoodlePath.last?.refreshesOnItsOwn ?? false)
    }

    @ViewBuilder
    private func courseDetailOverlay(slot: SelectedSlot) -> some View {
        let block = slot.course.block(weekday: slot.weekday, at: slot.periodId, in: visiblePeriods)
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { selectedSlot = nil }

            CourseDetailSheet(
                course: slot.course,
                assignments: shownPerson == nil
                    ? DataCache.shared.loadAssignments().unfinished(for: slot.course.courseNo)
                    : [],
                timeRange: block.flatMap(SDCourse.timeRange(periods:)) ?? slot.course.timeRange(for: slot.weekday),
                weekday: slot.weekday,
                periods: block,
                moodlePath: $detailMoodlePath,
                showsMoodle: shownPerson == nil
            )
            .frame(maxWidth: 560, maxHeight: 620)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .onTapGesture { }

            Button("") {
                if detailMoodlePath.isEmpty {
                    selectedSlot = nil
                } else {
                    detailMoodlePath.removeLast()
                }
            }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .transition(.opacity)
    }

    private func warmCachesIfNeeded() async {
        guard !hasWarmedCaches else { return }
        hasWarmedCaches = true
        await AppServiceBridge.warmAllSemesterCaches(authService: appState.authService)
        await MainActor.run {
            cacheRevision &+= 1
            followNewestSemesterIfUnpicked()
        }
    }

    private func followNewestSemesterIfUnpicked() {
        guard shownPerson == nil,
              Defaults[.classTableSelectedSemester] == nil,
              let newest = SemesterCatalog.availableSemesters().first,
              newest != selectedSemester else { return }
        isFollowingNewestSemester = true
        selectedSemester = newest
    }

    private func ensureCurrentSemesterFetched() async {
        let target = selectedSemester
        guard shownPerson == nil, DataCache.shared.loadCourses(semester: target).isEmpty else { return }
        await MainActor.run { isLoadingSemester = true }
        _ = await AppServiceBridge.fetchCourses(
            authService: appState.authService,
            semester: target
        )
        await MainActor.run {
            if selectedSemester == target {
                isLoadingSemester = false
            }
            cacheRevision &+= 1
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "feature_class_table"))
                    .font(.largeTitle.bold())
                Text(String(
                    format: String(localized: "desktop_class_table_subtitle_value"),
                    displayLabel(for: selectedSemester),
                    courses.count,
                    totalCredits.creditsText
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
        let store = ImportedClassTableStore.shared
        if store.hasImportedClassTables {
            let userName = ClassTableSwitcherEntry.userName(studentId: appState.authService.storedStudentId)
            let name = shownPerson?.nickname ?? userName
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

    private var otherPersonActions: some View {
        let sections = ClassTableOtherPersonAction.sections
            .map { $0.filter { $0 != .exportScreenshot } }
            .filter { !$0.isEmpty }
        return Menu {
            ForEach(sections, id: \.self) { section in
                Section {
                    ForEach(section, id: \.self) { action in
                        Button(role: action.role) {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: "class_table_more_actions"), systemImage: "ellipsis.circle")
        }
        .help(String(localized: "class_table_more_actions"))
    }

    private func requestImport() {
        guard importModel?.isLookingUp != true, importModel?.isReadingImage != true else { return }
        showImportPicker = true
    }

    private func perform(_ action: ClassTableOtherPersonAction) {
        switch action {
        case .exportScreenshot:
            break
        case .importClassTable:
            requestImport()
        case .rename:
            personInAlert = shownPerson
            nicknameDraft = shownPerson?.nickname ?? ""
            isRenamingPerson = true
        case .deleteUser:
            personInAlert = shownPerson
            isDeletingPerson = true
        }
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
            Text(String(format: String(localized: "desktop_class_table_loading_value"), displayLabel(for: selectedSemester)))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }


    private func openShareSheet() {
        guard let studentId = appState.authService.storedStudentId else { return }
        let terms = ClassTableShareModel.terms(
            in: availableSemesters, shownTerm: .init(semester: selectedSemester, courses: courses)
        )
        guard !terms.isEmpty else { return }
        shareModel = ClassTableShareModel(
            studentId: studentId,
            terms: terms,
            semesterLabel: displayLabel(for:)
        )
    }

    private var totalCredits: Double {
        courses.reduce(0) { $0 + $1.credits }
    }

    private func displayLabel(for code: String) -> String {
        guard code.count >= 2 else { return code }
        return String(code.dropLast()) + "-" + String(code.last!)
    }

    var isViewingCurrentSemester: Bool {
        selectedSemester == CourseSelectionService.currentSemesterCode()
    }

}
#endif

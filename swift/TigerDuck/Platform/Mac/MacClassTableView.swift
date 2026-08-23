#if os(macOS)
import SwiftUI
import Defaults

/// macOS Class Table — weekday × period grid that matches the iPhone
/// visual contract.
///
/// Cells share the same glassy treatment as iOS (`.ultraThinMaterial`
/// + `course.color.opacity(0.4)` + thin tinted stroke), and — like
/// iPhone — *consecutive periods of the same course are rendered as a
/// single block* spanning all of those rows rather than as repeated
/// cells. The grid is implemented as one VStack per weekday so each
/// weekday can independently span its cells without needing
/// SwiftUI Grid row-spanning (which doesn't exist).
///
/// The grid drawing and the schedule mutations live next door in
/// MacClassTableView+Grid.swift and MacClassTableView+Editing.swift. Swift's
/// `private` is file-scoped, so the state below reads `internal` rather than
/// `private` purely to be reachable from those two files — nothing outside
/// this trio should touch it, and in particular nothing should feed these
/// through the memberwise init, which would defeat `@State`.
struct MacClassTableView: View {
    @Environment(AppState.self) var appState

    @State var selectedSemester: String = SemesterCatalog.selectedSemester(
        storedPick: Defaults[.classTableSelectedSemester]
    )
    /// Set only while `warmCachesIfNeeded` moves the selection to the newest
    /// term, so that assignment doesn't get recorded as a user pick.
    @State private var isFollowingNewestSemester = false
    @State var selectedSlot: SelectedSlot?
    @State private var showAddCourse: Bool = false
    /// Non-nil while the macOS color picker sheet is presented. Set from the
    /// per-cell context menu; the iOS path stores this on its view-model, but
    /// the Mac classtable is a plain View so it lives in @State here.
    @State var courseToRecolor: SDCourse?

    /// Rename state — mirrors the iOS `ClassTableViewModel` triple
    /// (`courseToRename`, `renameText`, `showRenameAlert`). Mac has no
    /// view-model so it lives on the view directly.
    @State var courseToRename: SDCourse?
    @State var renameText: String = ""
    @State var showRenameAlert: Bool = false

    /// Carries the weekday alongside the tapped course so the detail sheet
    /// can render the concrete slot's classroom + time range. Without the
    /// weekday context, `CourseDetailSheet` falls back to the aggregate
    /// classroom and shows `—` for the time card.
    struct SelectedSlot: Identifiable {
        let course: SDCourse
        let weekday: Int
        var id: String { "\(course.courseNo)-\(weekday)" }
    }
    /// Bumps whenever an async fetch lands new cache; the body's
    /// `courses` computed read includes this to trigger re-render
    /// (Observation can't see plain `DataCache` mutations).
    @State var cacheRevision: Int = 0
    @State private var hasWarmedCaches = false
    @State private var isLoadingSemester = false
    @State var tripleConflictError: TripleConflictError?

    /// Identifies a slot the add path tried to push into when it would
    /// have become a 3-course slot. `existing` is the two courses already
    /// scheduled there so the alert can name them.
    struct TripleConflictError: Identifiable {
        let id = UUID()
        let weekday: Int
        let periodId: String
        let newCourseName: String
        let existingA: SDCourse
        let existingB: SDCourse
    }

    /// Mon–Fri by default; weekend columns appear only when a loaded
    /// schedule actually places a course on Sat/Sun, matching the
    /// iPhone `activeWeekdays` behavior.
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

    /// Computed, not stored: `SemesterCatalog.refresh()` runs inside the
    /// cache warm below, so a term published mid-session has to be able to
    /// appear without rebuilding the view. `selectedSemester` is folded in so
    /// a persisted selection that aged out of the window still renders its label.
    private var availableSemesters: [String] {
        let options = SemesterCatalog.availableSemesters()
        return options.contains(selectedSemester) ? options : options + [selectedSemester]
    }

    var courses: [SDCourse] {
        _ = cacheRevision
        // Route through the canonical merge so the deletedCourseNos
        // tombstone filter and customNames overlay apply here too. The Mac
        // picker can target a past semester, so we can't call
        // `CanonicalCourseProvider.currentCourses()` (which is pinned to
        // the live `CourseSelectionService` semester) — feed the static
        // `merge` directly with per-semester inputs instead.
        let cached = DataCache.shared.loadCourses(semester: selectedSemester)
        let userAdded = DataCache.shared.loadUserAddedCourses(semester: selectedSemester)
        return CanonicalCourseProvider.merge(
            primary: cached,
            userAdded: userAdded,
            deletedCourseNos: Set(DataCache.shared.loadDeletedCourseNos()),
            customNames: DataCache.shared.loadCourseCustomNamesFlat()
        )
    }

    var visiblePeriods: [String] {
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
            ToolbarItem(placement: .automatic) {
                Button {
                    showAddCourse = true
                } label: {
                    // A bare `Label(...)` in a macOS toolbar renders the
                    // plus glyph and the title with mismatched baselines
                    // (image floats high). Spelling out the HStack and
                    // letting both views use their default alignment
                    // produces the same row geometry as the semester picker
                    // sitting beside this button. `.fixedSize` stops AppKit
                    // from compressing the label down to icon-only (and
                    // floating the glyph against the right edge) when the
                    // semester picker grows wide.
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(String(localized: "add_course_title"))
                    }
                    .fixedSize()
                }
                .help(String(localized: "add_course_title"))
            }
        }
        .sheet(isPresented: $showAddCourse) {
            AddCourseSheet(
                semester: selectedSemester,
                existingCourseNos: Set(courses.map(\.courseNo)),
                onAdd: { addUserCourse($0) },
                onRemove: { removeUserAddedCourse(courseNo: $0) }
            )
            // Conflict alert lives on the sheet's content: on iPhone
            // hosting an alert on the parent forces SwiftUI to dismiss the
            // sheet to present it. macOS doesn't have the same dismissal,
            // but keeping both platforms anchored to the sheet keeps the
            // alert visually attached to the search results either way.
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
                    "\(err.weekday)",
                    err.periodId,
                    err.existingA.displayName,
                    err.existingB.displayName
                ))
            }
        }
        .sheet(item: $courseToRecolor) { course in
            CourseColorPickerSheet(
                course: course,
                onSelect: { hex in
                    TigerDuckTheme.setColor(hex: hex, for: course.courseNo)
                    cacheRevision &+= 1
                    NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
                    if let moodleId = course.moodleIdNumber {
                        appState.syncCourseOverride(moodleCourseId: moodleId, colorHex: String(format: "#%06X", hex))
                    }
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
        .task {
            await warmCachesIfNeeded()
            await ensureCurrentSemesterFetched()
        }
        .onChange(of: selectedSemester) { _, newValue in
            if isFollowingNewestSemester {
                isFollowingNewestSemester = false
            } else {
                Defaults[.classTableSelectedSemester] = newValue
            }
            Task { await ensureCurrentSemesterFetched() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)) { _ in
            cacheRevision &+= 1
        }
        // Course detail uses a custom overlay (not `.sheet`) so the user can
        // dismiss by clicking the backdrop — macOS sheets are window-modal
        // and swallow all outside clicks, leaving ESC as the only escape.
        .overlay {
            if let slot = selectedSlot {
                courseDetailOverlay(slot: slot)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: selectedSlot?.id)
    }

    @ViewBuilder
    private func courseDetailOverlay(slot: SelectedSlot) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { selectedSlot = nil }

            CourseDetailSheet(
                course: slot.course,
                assignments: DataCache.shared.loadAssignments().unfinished(for: slot.course.courseNo),
                timeRange: slot.course.timeRange(for: slot.weekday),
                weekday: slot.weekday
            )
            // Max-bound rather than fixed: a small window (e.g. MacBook Air
            // with the inspector open) shrinks the overlay to fit, while
            // larger windows give the inner ScrollView more room before it
            // has to scroll. `CourseDetailSheet` enforces its own minWidth
            // 460 / minHeight 360 so the lower bound is preserved.
            .frame(maxWidth: 560, maxHeight: 620)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            // Swallow taps on the content so they don't reach the backdrop.
            .onTapGesture { }

            // Restore ESC dismissal — custom overlays don't inherit a sheet's
            // automatic cancel handling. Hidden button keeps the shortcut
            // active without affecting the visible layout.
            Button("") { selectedSlot = nil }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .transition(.opacity)
    }

    // MARK: - Async fetch

    /// One-shot warm of historical semester caches when the view first
    /// appears. iPhone runs the same warm inside `ClassTableViewModel`;
    /// the Mac picker can offer the past 4 semesters but only the
    /// current one ships in the day-zero cache, so without this the
    /// picker silently shows an empty grid for previous terms.
    private func warmCachesIfNeeded() async {
        guard !hasWarmedCaches else { return }
        hasWarmedCaches = true
        await AppServiceBridge.warmAllSemesterCaches(authService: appState.authService)
        await MainActor.run {
            cacheRevision &+= 1
            followNewestSemesterIfUnpicked()
        }
    }

    /// The catalogue can land after the view is built on a cold launch, so
    /// re-apply the "never picked → newest term" rule once it does.
    private func followNewestSemesterIfUnpicked() {
        guard Defaults[.classTableSelectedSemester] == nil,
              let newest = SemesterCatalog.availableSemesters().first,
              newest != selectedSemester else { return }
        isFollowingNewestSemester = true
        selectedSemester = newest
    }

    /// Fetch the currently-selected semester if its cache is empty.
    /// Covers the case where the user picked a semester before
    /// `warmCachesIfNeeded` finished (or where the warm skipped it
    /// because cache was empty for a different reason than "never
    /// fetched").
    private func ensureCurrentSemesterFetched() async {
        let target = selectedSemester
        guard DataCache.shared.loadCourses(semester: target).isEmpty else { return }
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

    // MARK: - Header / empty state

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "feature_class_table"))
                    .font(.largeTitle.bold())
                Text(String(
                    format: String(localized: "desktop_class_table_subtitle_value"),
                    displayLabel(for: selectedSemester),
                    courses.count,
                    totalCredits
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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


    // MARK: - Helpers

    private var totalCredits: Int {
        courses.reduce(0) { $0 + $1.credits }
    }

    private func displayLabel(for code: String) -> String {
        guard code.count >= 2 else { return code }
        return String(code.dropLast()) + "-" + String(code.last!)
    }

    /// True when the Mac picker is on the currently-enrolled semester.
    /// Rename and Delete are gated on this because their on-disk stores
    /// (`courseCustomNames`, `deletedCourseNos`) are keyed by `courseNo`
    /// only — a write made while viewing a past term would leak into the
    /// current schedule, widgets, and Live Activity for any course that
    /// reuses the same code.
    var isViewingCurrentSemester: Bool {
        selectedSemester == CourseSelectionService.currentSemesterCode()
    }

}
#endif

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
struct MacClassTableView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedSemester: String = Defaults[.classTableSelectedSemester]
    @State private var selectedSlot: SelectedSlot?
    @State private var showAddCourse: Bool = false
    /// Non-nil while the macOS color picker sheet is presented. Set from the
    /// per-cell context menu; the iOS path stores this on its view-model, but
    /// the Mac classtable is a plain View so it lives in @State here.
    @State private var courseToRecolor: SDCourse?

    /// Rename state — mirrors the iOS `ClassTableViewModel` triple
    /// (`courseToRename`, `renameText`, `showRenameAlert`). Mac has no
    /// view-model so it lives on the view directly.
    @State private var courseToRename: SDCourse?
    @State private var renameText: String = ""
    @State private var showRenameAlert: Bool = false

    /// Carries the weekday alongside the tapped course so the detail sheet
    /// can render the concrete slot's classroom + time range. Without the
    /// weekday context, `CourseDetailSheet` falls back to the aggregate
    /// classroom and shows `—` for the time card.
    private struct SelectedSlot: Identifiable {
        let course: SDCourse
        let weekday: Int
        var id: String { "\(course.courseNo)-\(weekday)" }
    }
    /// Bumps whenever an async fetch lands new cache; the body's
    /// `courses` computed read includes this to trigger re-render
    /// (Observation can't see plain `DataCache` mutations).
    @State private var cacheRevision: Int = 0
    @State private var hasWarmedCaches = false
    @State private var isLoadingSemester = false
    @State private var tripleConflictError: TripleConflictError?

    /// Identifies a slot the add path tried to push into when it would
    /// have become a 3-course slot. `existing` is the two courses already
    /// scheduled there so the alert can name them.
    private struct TripleConflictError: Identifiable {
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
    private var weekdays: [Int] {
        let occupied = Set(courses.flatMap { $0.schedule.keys })
        var days = Array(1...5)
        if occupied.contains(6) { days.append(6) }
        if occupied.contains(7) { days.append(7) }
        return days
    }

    private let cellHeight: CGFloat = 56
    private let rowSpacing: CGFloat = 4
    private let periodLabelWidth: CGFloat = 56

    private let availableSemesters: [String] = {
        let code = CourseSelectionService.currentSemesterCode()
        let yearStr = String(code.dropLast())
        guard let year = Int(yearStr),
              let lastChar = code.last,
              let s0 = Int(String(lastChar)) else {
            return [code]
        }
        var semesters: [String] = []
        var y = year
        var s = s0
        for _ in 0..<4 {
            semesters.append("\(y)\(s)")
            s -= 1
            if s < 1 { s = 2; y -= 1 }
        }
        return semesters
    }()

    private var courses: [SDCourse] {
        _ = cacheRevision
        // Route through the canonical merge so the deletedCourseNos
        // tombstone filter and customNames overlay apply here too. The Mac
        // picker can target a past semester, so we can't call
        // `CanonicalCourseProvider.currentCourses()` (which is pinned to
        // the live `CourseSelectionService` semester) — feed the static
        // `merge` directly with per-semester inputs instead.
        let cached = DataCache.shared.loadCourses(semester: selectedSemester)
        let userAdded = DataCache.shared.loadUserAddedCourses()
            .filter { $0.semester == selectedSemester || $0.semester.isEmpty }
        return CanonicalCourseProvider.merge(
            primary: cached,
            userAdded: userAdded,
            deletedCourseNos: Set(DataCache.shared.loadDeletedCourseNos()),
            customNames: DataCache.shared.loadCourseCustomNamesFlat()
        )
    }

    private var visiblePeriods: [String] {
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
            Defaults[.classTableSelectedSemester] = newValue
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
        await MainActor.run { cacheRevision &+= 1 }
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

    // MARK: - Glass grid card

    private var glassGridCard: some View {
        VStack(spacing: rowSpacing) {
            headerRow
            HStack(alignment: .top, spacing: rowSpacing) {
                periodLabelColumn
                ForEach(weekdays, id: \.self) { weekday in
                    weekdayColumn(weekday)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }

    private var headerRow: some View {
        HStack(spacing: rowSpacing) {
            Color.clear.frame(width: periodLabelWidth, height: 22)
            ForEach(weekdays, id: \.self) { weekday in
                Text(weekdayLabel(weekday))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        switch weekday {
        case 1...5: return AppConstants.Periods.weekdays[safe: weekday - 1] ?? "?"
        case 6: return AppConstants.Periods.weekendDays[safe: 0] ?? "?"
        case 7: return AppConstants.Periods.weekendDays[safe: 1] ?? "?"
        default: return "?"
        }
    }

    private var periodLabelColumn: some View {
        VStack(spacing: rowSpacing) {
            ForEach(visiblePeriods, id: \.self) { period in
                periodLabel(period)
                    .frame(height: cellHeight)
            }
        }
        .frame(width: periodLabelWidth)
    }

    private func periodLabel(_ period: String) -> some View {
        let times = AppConstants.PeriodTimes.mapping[period]
        return VStack(alignment: .trailing, spacing: 2) {
            Text(period)
                .font(.subheadline.weight(.semibold))
            if let times {
                Text(times.start)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(times.end)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 4)
    }

    /// One vertical stack of cells for `weekday`. Walks `visiblePeriods` one
    /// row at a time; `ClassTableLayout.cellRole` tells us when a row is the
    /// start of a multi-row block (solo or 衝堂 cluster) so contiguous runs
    /// render as a single tall block — same partitioning the iPhone uses.
    @ViewBuilder
    private func weekdayColumn(_ weekday: Int) -> some View {
        let periods = visiblePeriods
        VStack(spacing: rowSpacing) {
            ForEach(periods.indices, id: \.self) { index in
                let role = ClassTableLayout.cellRole(
                    courses: courses,
                    periodIds: periods,
                    weekday: weekday,
                    periodIndex: index,
                    keyOf: { $0.courseNo },
                    scheduleOf: { $0.schedule }
                )
                cellView(role: role, weekday: weekday)
            }
        }
    }

    @ViewBuilder
    private func cellView(role: ClassTableCellRole<SDCourse>, weekday: Int) -> some View {
        switch role {
        case .empty:
            emptyCell.frame(height: cellHeight)
        case let .solo(course, spanCount):
            courseCell(course)
                .frame(height: blockHeight(spanCount))
                .onTapGesture { selectedSlot = SelectedSlot(course: course, weekday: weekday) }
        case let .conflictStart(a, spanA, offsetA, b, spanB, offsetB, combinedSpan):
            // 衝堂 renders as a horizontal split where each half is a column
            // sized to that course's actual span and positioned at its
            // offset within the cluster. Without offset-aware columns,
            // mismatched spans (e.g. A on periods 1–3 overlapping B only on
            // period 2) would show B as a full-height column and make it
            // clickable in rows where the two courses don't actually meet.
            HStack(spacing: rowSpacing) {
                conflictColumn(course: a, span: spanA, offset: offsetA, combinedSpan: combinedSpan, weekday: weekday)
                conflictColumn(course: b, span: spanB, offset: offsetB, combinedSpan: combinedSpan, weekday: weekday)
            }
            .frame(height: blockHeight(combinedSpan))
        case let .conflictMany(segments, combinedSpan):
            // Same offset-aware column layout as the 2-course case
            // above, just N columns wide. Each segment gets a column
            // sized to its own span and positioned at its offset, so a
            // staircase like A(rows 0-1) / B(rows 1-2) / C(rows 2-3)
            // paints each course only in the rows it actually occupies.
            HStack(spacing: rowSpacing) {
                ForEach(segments, id: \.course.courseNo) { segment in
                    conflictColumn(
                        course: segment.course,
                        span: segment.span,
                        offset: segment.offset,
                        combinedSpan: combinedSpan,
                        weekday: weekday
                    )
                }
            }
            .frame(height: blockHeight(combinedSpan))
        case .skip:
            EmptyView()
        }
    }

    private func blockHeight(_ span: Int) -> CGFloat {
        CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
    }

    /// One column of a 衝堂 cluster. Empty spacers above/below the course
    /// block reserve the rows the course isn't scheduled in so an overlap
    /// only meeting in part of the cluster doesn't extend to the rest.
    @ViewBuilder
    private func conflictColumn(course: SDCourse, span: Int, offset: Int, combinedSpan: Int, weekday: Int) -> some View {
        let bottom = max(combinedSpan - offset - span, 0)
        VStack(spacing: rowSpacing) {
            if offset > 0 {
                Color.clear.frame(height: blockHeight(offset))
            }
            courseCell(course)
                .frame(height: blockHeight(span))
                .onTapGesture { selectedSlot = SelectedSlot(course: course, weekday: weekday) }
                .accessibilityLabel(Text(course.displayName))
            if bottom > 0 {
                Color.clear.frame(height: blockHeight(bottom))
            }
        }
    }

    private var emptyCell: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
            )
    }

    private func courseCell(_ course: SDCourse) -> some View {
        let color = TigerDuckTheme.courseColor(for: course.courseNo)
        return VStack(alignment: .leading, spacing: 3) {
            Text(course.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            if !course.instructor.isEmpty {
                Text(course.instructor)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.4))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.6), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .contextMenu {
            // Rename writes to a courseNo-keyed store shared across semesters;
            // only expose it from the current semester to avoid leaking aliases
            // into other terms. See `isViewingCurrentSemester`.
            if isViewingCurrentSemester {
                Button {
                    startRename(course)
                } label: {
                    Label(String(localized: "class_table_rename_title"), systemImage: "pencil")
                }
            }
            Button {
                courseToRecolor = course
            } label: {
                Label(String(localized: "course_color_picker_title"), systemImage: "paintpalette")
            }
            if isViewingCurrentSemester {
                Divider()
                Button(role: .destructive) {
                    deleteCourse(course)
                } label: {
                    Label(String(localized: "class_table_delete"), systemImage: "trash")
                }
            }
        }
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
    private var isViewingCurrentSemester: Bool {
        selectedSemester == CourseSelectionService.currentSemesterCode()
    }

    // MARK: - User-added courses

    /// Append a user-added course to the on-disk store and refresh the grid.
    /// Mirrors the parts of `ClassTableViewModel.addCourse(_:)` that are load-
    /// bearing on macOS: tombstone clear, NameAbbr cache seeding so toggles
    /// round-trip without a refetch, and a `dataDidUpdate` broadcast so the
    /// Home page's widget cards also re-render. Returns `true` iff the
    /// course was newly persisted so the AddCourseSheet only flips its
    /// session checkmark on real adds — otherwise a duplicate-rejected tap
    /// would route the next tap through `removeUserAddedCourse` and delete
    /// the pre-existing user-added course for this semester.
    @discardableResult
    private func addUserCourse(_ course: SDCourse) -> Bool {
        let existing = DataCache.shared.loadUserAddedCourses()
        // Dedupe within the selected semester only — the same `courseNo`
        // legitimately recurs across terms (a recurring elective added
        // manually in both 1131 and 1132), and `removeUserAddedCourse`
        // already scopes its undo to `selectedSemester`. `courses`
        // already reflects the current semester's roster so its
        // duplicate check stays semester-scoped implicitly.
        let isInSelectedSemester: (SDCourse) -> Bool = {
            $0.semester == selectedSemester || $0.semester.isEmpty
        }
        guard !existing.contains(where: { $0.courseNo == course.courseNo && isInSelectedSemester($0) }),
              !courses.contains(where: { $0.courseNo == course.courseNo })
        else { return false }

        // Refuse if any slot the candidate would occupy already has 2
        // courses. The shared `ClassTableLayout` can render N-way conflicts,
        // but persisting 3+ in a slot is still a bug surface (Android caps
        // at 2 and the iPhone path rejects too). Must run BEFORE tombstone
        // clear, otherwise a rejected add leaves a tombstone cleared and the
        // next reload would resurrect the course.
        if let err = firstTripleConflict(for: course) {
            tripleConflictError = err
            return false
        }

        var deleted = Set(DataCache.shared.loadDeletedCourseNos())
        if deleted.remove(course.courseNo) != nil {
            DataCache.shared.saveDeletedCourseNos(Array(deleted))
        }

        NameAbbrService.shared.storeRawName(
            courseNo: course.courseNo, name: course.courseName
        )
        NameAbbrService.shared.storeRawClassroom(
            courseNo: course.courseNo,
            classroom: course.classroom,
            map: course.classroomMap
        )

        DataCache.shared.saveUserAddedCourses(existing + [course])
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        appState.uploadCourses(courses + [course], semester: selectedSemester)
        return true
    }

    /// Scans every slot `candidate` would occupy and returns the first one
    /// that already has two courses — adding the candidate there would push
    /// it to three. Returns nil when the add is safe.
    private func firstTripleConflict(for candidate: SDCourse) -> TripleConflictError? {
        for (weekday, periodIds) in candidate.schedule {
            for pid in periodIds {
                let occupants = courses.filter {
                    ($0.schedule[weekday] ?? []).contains(pid)
                }
                if occupants.count >= 2 {
                    return TripleConflictError(
                        weekday: weekday,
                        periodId: pid,
                        newCourseName: candidate.displayName,
                        existingA: occupants[0],
                        existingB: occupants[1]
                    )
                }
            }
        }
        return nil
    }

    /// Undo a not-yet-committed user-added course without tombstoning the
    /// `courseNo`. Tap-to-toggle in `AddCourseSheet` routes here when the user
    /// adds and immediately removes a course in the same session.
    /// Scoped to the currently-selected semester so undoing `X` here doesn't
    /// also delete a manually-added `X` the user saved for a different
    /// semester (the sheet's onRemove callback only carries the courseNo).
    private func removeUserAddedCourse(courseNo: String) {
        let existing = DataCache.shared.loadUserAddedCourses()
        let updated = existing.filter { course in
            !(course.courseNo == courseNo && (course.semester == selectedSemester || course.semester.isEmpty))
        }
        guard updated.count != existing.count else { return }
        DataCache.shared.saveUserAddedCourses(updated)
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        appState.uploadCourses(courses.filter { $0.courseNo != courseNo }, semester: selectedSemester)
    }

    // MARK: - Rename

    /// Right-click "Rename" — opens the rename alert pre-filled with the
    /// course's current display name. Mirrors `ClassTableViewModel.startRename`.
    private func startRename(_ course: SDCourse) {
        courseToRename = course
        renameText = course.displayName
        showRenameAlert = true
    }

    /// Commit the typed alias to `DataCache.courseCustomNames`. Empty or
    /// equal-to-canonical input is treated as a revert so the user can clear
    /// the override by typing nothing. Mirrors the iPhone confirmRename rules
    /// 1:1 so renames stay consistent across platforms.
    private func confirmRename() {
        guard let course = courseToRename else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == course.courseName {
            revertRename(course)
            return
        }
        let locale = LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
        var names = DataCache.shared.loadCourseCustomNames()
        names[course.courseNo, default: [:]][locale] = trimmed
        DataCache.shared.saveCourseCustomNames(names)
        courseToRename = nil
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        if let moodleId = course.moodleIdNumber {
            appState.syncCourseOverride(moodleCourseId: moodleId, customName: trimmed, locale: locale)
        }
    }

    /// Clear the alias so `displayName` falls back to the canonical NTUST
    /// course name. Also surfaced as the destructive button in the rename
    /// alert when an override is already set.
    private func revertRename(_ course: SDCourse) {
        let locale = LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
        var names = DataCache.shared.loadCourseCustomNames()
        names[course.courseNo]?[locale] = nil
        if names[course.courseNo]?.isEmpty == true {
            names.removeValue(forKey: course.courseNo)
        }
        DataCache.shared.saveCourseCustomNames(names)
        courseToRename = nil
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        if let moodleId = course.moodleIdNumber {
            appState.syncCourseOverride(moodleCourseId: moodleId, customName: "", locale: locale)
        }
    }

    /// Right-click "Delete" — mirrors `ClassTableViewModel.deleteCourse` on
    /// iPhone. Tombstones the courseNo so a future cache refresh from NTUST
    /// can't resurrect a course the user deliberately removed, AND drops any
    /// user-added entry for the courseNo in this semester so the row vanishes
    /// immediately whether the source was an enrolled course or a manual add.
    private func deleteCourse(_ course: SDCourse) {
        var deleted = Set(DataCache.shared.loadDeletedCourseNos())
        deleted.insert(course.courseNo)
        DataCache.shared.saveDeletedCourseNos(Array(deleted))

        let existing = DataCache.shared.loadUserAddedCourses()
        let pruned = existing.filter { entry in
            !(entry.courseNo == course.courseNo && (entry.semester == selectedSemester || entry.semester.isEmpty))
        }
        if pruned.count != existing.count {
            DataCache.shared.saveUserAddedCourses(pruned)
        }

        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        appState.deleteBackendCourse(courseNo: course.courseNo, semester: selectedSemester)
        appState.uploadCourses(courses.filter { $0.courseNo != course.courseNo }, semester: selectedSemester)
    }
}
#endif

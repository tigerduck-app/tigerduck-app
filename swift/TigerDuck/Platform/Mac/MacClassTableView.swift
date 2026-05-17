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
    @State private var selectedCourse: SDCourse?
    @State private var showAddCourse: Bool = false
    /// Bumps whenever an async fetch lands new cache; the body's
    /// `courses` computed read includes this to trigger re-render
    /// (Observation can't see plain `DataCache` mutations).
    @State private var cacheRevision: Int = 0
    @State private var hasWarmedCaches = false
    @State private var isLoadingSemester = false

    /// Mon–Fri only — Sat/Sun are hidden on iPhone too unless data forces them.
    private let weekdays: [Int] = [1, 2, 3, 4, 5]

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
        let cached = DataCache.shared.loadCourses(semester: selectedSemester)
        let userAdded = DataCache.shared.loadUserAddedCourses()
            .filter { $0.semester == selectedSemester || $0.semester.isEmpty }
        return cached + userAdded
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
                    Label(String(localized: "class_table_add_course"), systemImage: "plus")
                }
                .help(String(localized: "class_table_add_course"))
            }
        }
        .sheet(item: $selectedCourse) { course in
            CourseDetailSheet(
                course: course,
                assignments: DataCache.shared.loadAssignments().unfinished(for: course.courseNo)
            )
        }
        .sheet(isPresented: $showAddCourse) {
            AddCourseSheet(
                semester: selectedSemester,
                existingCourseNos: Set(courses.map(\.courseNo)),
                onAdd: { addUserCourse($0) },
                onRemove: { removeUserAddedCourse(courseNo: $0) }
            )
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
            ForEach(weekdays.indices, id: \.self) { idx in
                Text(AppConstants.Periods.weekdays[safe: idx] ?? "?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
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
                cellView(role: role)
            }
        }
    }

    @ViewBuilder
    private func cellView(role: ClassTableCellRole<SDCourse>) -> some View {
        switch role {
        case .empty:
            emptyCell.frame(height: cellHeight)
        case let .solo(course, spanCount):
            courseCell(course)
                .frame(height: blockHeight(spanCount))
                .onTapGesture { selectedCourse = course }
        case let .conflictStart(a, _, _, b, _, _, combinedSpan):
            // macOS renders 衝堂 as a horizontal split for the full cluster
            // height. Cleaner than the iPhone L-shape interlock (which needs
            // offset-aware geometry) but still surfaces both courses and
            // makes each independently clickable.
            HStack(spacing: rowSpacing) {
                courseCell(a)
                    .onTapGesture { selectedCourse = a }
                    .accessibilityLabel(Text(a.displayName))
                courseCell(b)
                    .onTapGesture { selectedCourse = b }
                    .accessibilityLabel(Text(b.displayName))
            }
            .frame(height: blockHeight(combinedSpan))
        case .skip:
            EmptyView()
        }
    }

    private func blockHeight(_ span: Int) -> CGFloat {
        CGFloat(span) * cellHeight + CGFloat(max(span - 1, 0)) * rowSpacing
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
    }

    // MARK: - Helpers

    private var totalCredits: Int {
        courses.reduce(0) { $0 + $1.credits }
    }

    private func displayLabel(for code: String) -> String {
        guard code.count >= 2 else { return code }
        return String(code.dropLast()) + "-" + String(code.last!)
    }

    // MARK: - User-added courses

    /// Append a user-added course to the on-disk store and refresh the grid.
    /// Mirrors the parts of `ClassTableViewModel.addCourse(_:)` that are load-
    /// bearing on macOS: tombstone clear, NameAbbr cache seeding so toggles
    /// round-trip without a refetch, and a `dataDidUpdate` broadcast so the
    /// Home page's widget cards also re-render. Triple-conflict guarding is
    /// left to a future macOS pass (iPhone's `wouldCauseTripleConflict` lives
    /// inside `ClassTableViewModel` and isn't reusable yet).
    private func addUserCourse(_ course: SDCourse) {
        let existing = DataCache.shared.loadUserAddedCourses()
        guard !existing.contains(where: { $0.courseNo == course.courseNo }),
              !courses.contains(where: { $0.courseNo == course.courseNo })
        else { return }

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
    }

    /// Undo a not-yet-committed user-added course without tombstoning the
    /// `courseNo`. Tap-to-toggle in `AddCourseSheet` routes here when the user
    /// adds and immediately removes a course in the same session.
    private func removeUserAddedCourse(courseNo: String) {
        let existing = DataCache.shared.loadUserAddedCourses()
        guard existing.contains(where: { $0.courseNo == courseNo }) else { return }
        DataCache.shared.saveUserAddedCourses(existing.filter { $0.courseNo != courseNo })
        cacheRevision &+= 1
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
    }
}
#endif

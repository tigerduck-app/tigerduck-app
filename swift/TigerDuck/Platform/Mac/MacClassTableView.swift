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
        }
        .sheet(item: $selectedCourse) { course in
            courseDetailSheet(course)
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
            isLoadingSemester = false
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

    /// One vertical stack of cells for `weekday`. Walks `visiblePeriods`
    /// merging contiguous runs of the same course into a single tall
    /// block (matching iPhone's `TimetableGridView` semantics). When two
    /// courses overlap on the same period, the first course's name is
    /// shown with a "+N" badge — Mac doesn't render the L-shape
    /// interlock the iOS grid uses, but the conflict is still surfaced.
    @ViewBuilder
    private func weekdayColumn(_ weekday: Int) -> some View {
        let segments = segments(for: weekday)
        VStack(spacing: rowSpacing) {
            ForEach(segments.indices, id: \.self) { index in
                let seg = segments[index]
                let height = CGFloat(seg.span) * cellHeight + CGFloat(seg.span - 1) * rowSpacing
                segmentView(seg)
                    .frame(height: height)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: CellSegment) -> some View {
        if let course = segment.course {
            courseCell(course, conflicts: segment.conflicts)
                .onTapGesture { selectedCourse = course }
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.04), lineWidth: 0.5)
                )
        }
    }

    private func courseCell(_ course: SDCourse, conflicts: Int) -> some View {
        let color = TigerDuckTheme.courseColor(for: course.courseNo)
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
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

            if conflicts > 0 {
                Text("+\(conflicts)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.black.opacity(0.55))
                    )
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Cell segmentation

    /// A contiguous block in one weekday column. `course` is nil for an
    /// empty gap; `conflicts` is the number of additional courses that
    /// share the first period of this block (0 for a clean run).
    private struct CellSegment {
        let course: SDCourse?
        let span: Int
        let conflicts: Int
    }

    /// Merge contiguous same-course runs into single segments. For
    /// conflicts (multiple courses on one period), the first course
    /// wins the cell with a `+N` badge and the run length collapses to
    /// 1 — we don't try to merge "course A spans periods 1-3 AND
    /// course B spans periods 2-4" because the L-shape rendering for
    /// that case is non-trivial and rare on the Mac surface.
    private func segments(for weekday: Int) -> [CellSegment] {
        let periods = visiblePeriods
        var result: [CellSegment] = []
        var i = 0
        while i < periods.count {
            let period = periods[i]
            let matches = courses.filter { ($0.schedule[weekday] ?? []).contains(period) }
            if matches.isEmpty {
                result.append(CellSegment(course: nil, span: 1, conflicts: 0))
                i += 1
                continue
            }
            if matches.count >= 2 {
                result.append(CellSegment(
                    course: matches[0],
                    span: 1,
                    conflicts: matches.count - 1
                ))
                i += 1
                continue
            }
            // Solo course — find consecutive run length.
            let course = matches[0]
            var span = 1
            while i + span < periods.count {
                let nextPeriod = periods[i + span]
                let nextMatches = courses.filter { ($0.schedule[weekday] ?? []).contains(nextPeriod) }
                if nextMatches.count == 1, nextMatches[0].courseNo == course.courseNo {
                    span += 1
                } else {
                    break
                }
            }
            result.append(CellSegment(course: course, span: span, conflicts: 0))
            i += span
        }
        return result
    }

    // MARK: - Course detail sheet

    private func courseDetailSheet(_ course: SDCourse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle()
                    .fill(TigerDuckTheme.courseColor(for: course.courseNo))
                    .frame(width: 14, height: 14)
                Text(course.displayName)
                    .font(.title2.bold())
                Spacer()
                Button {
                    selectedCourse = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            detailRow(label: String(localized: "desktop_course_detail_course_no_label"), value: course.courseNo)
            if !course.instructor.isEmpty {
                detailRow(label: String(localized: "course_detail_instructor_label"), value: course.instructor)
            }
            detailRow(label: String(localized: "course_detail_credits_label"), value: "\(course.credits)")
            ForEach(course.schedule.keys.sorted(), id: \.self) { weekday in
                let periods = (course.schedule[weekday] ?? []).sortedByPeriodOrder().joined(separator: ", ")
                let room = course.classroom(for: weekday)
                let weekdayLabel = AppConstants.Periods.weekdays[safe: weekday - 1] ?? "?"
                detailRow(
                    label: weekdayLabel,
                    value: room.isEmpty ? periods : "\(periods)  ·  \(room)"
                )
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 440, height: 340)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
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
}
#endif

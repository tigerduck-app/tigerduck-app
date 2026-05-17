#if os(macOS)
import SwiftUI
import Defaults

/// macOS Class Table — weekday × period grid.
///
/// Reads the current semester's courses straight from DataCache and
/// renders a Grid laid out as 6 columns (1 period column + 5 weekday
/// columns) × N period rows. Each course occupies one cell per
/// (weekday, period) entry in its `schedule` dictionary, coloured by
/// the deterministic `TigerDuckTheme.courseColor`. Clicking a course
/// surfaces a Mac-native popover with details + classroom + instructor;
/// a separate top strip shows the active semester picker so users on
/// long-running terms can sample previous semesters' grids.
struct MacClassTableView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedSemester: String = Defaults[.classTableSelectedSemester]
    @State private var selectedCourse: SDCourse?

    /// Weekdays Mon-Fri only — Sat/Sun rarely have classes; iOS hides
    /// them too unless the data demands. Mac inherits the same default.
    private let weekdays: [Int] = [1, 2, 3, 4, 5]

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
        let cached = DataCache.shared.loadCourses(semester: selectedSemester)
        let userAdded = DataCache.shared.loadUserAddedCourses()
            .filter { $0.semester == selectedSemester || $0.semester.isEmpty }
        return cached + userAdded
    }

    /// Periods that any course in this semester actually occupies, in
    /// chronological order. Avoids drawing empty trailing periods
    /// (evening slots) when no class is scheduled there.
    private var visiblePeriods: [String] {
        let occupied = Set(courses.flatMap { $0.schedule.values.flatMap { $0 } })
        return AppConstants.Periods.chronologicalOrder.filter {
            AppConstants.Periods.defaultVisible.contains($0) || occupied.contains($0)
        }
    }

    var body: some View {
        ScrollView([.vertical]) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if courses.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Semester", selection: $selectedSemester) {
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
        .onChange(of: selectedSemester) { _, newValue in
            Defaults[.classTableSelectedSemester] = newValue
        }
    }

    // MARK: - Header / empty state

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Class Table")
                    .font(.title2.bold())
                Text("\(displayLabel(for: selectedSemester)) · \(courses.count) courses · \(totalCredits) credits")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No courses in this semester")
                .font(.headline)
            Text("⌘R fetches the latest course list from the NTUST portal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Grid

    private var grid: some View {
        let weekdayLabels = AppConstants.Periods.weekdays
        return Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            // Header row
            GridRow {
                Text("")
                    .frame(width: 64)
                ForEach(weekdays.indices, id: \.self) { idx in
                    Text(weekdayLabels.indices.contains(idx) ? weekdayLabels[idx] : "?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            // Period rows
            ForEach(visiblePeriods, id: \.self) { period in
                GridRow {
                    periodLabel(period)
                    ForEach(weekdays, id: \.self) { weekday in
                        cell(weekday: weekday, period: period)
                    }
                }
            }
        }
        .padding(.top, 4)
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
        .frame(width: 64, alignment: .trailing)
        .padding(.trailing, 4)
    }

    private func cell(weekday: Int, period: String) -> some View {
        let matches = courses.filter { ($0.schedule[weekday] ?? []).contains(period) }
        return Group {
            if let course = matches.first {
                courseCell(course, conflicts: matches.count - 1)
                    .onTapGesture {
                        selectedCourse = course
                    }
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.gray.opacity(0.06))
                    .frame(minHeight: 56)
            }
        }
    }

    private func courseCell(_ course: SDCourse, conflicts: Int) -> some View {
        let color = TigerDuckTheme.courseColor(for: course.courseNo)
        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.displayName)
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !course.instructor.isEmpty {
                    Text(course.instructor)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
            )

            if conflicts > 0 {
                Text("+\(conflicts)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.black.opacity(0.45))
                    )
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
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

            detailRow(label: "Course no.", value: course.courseNo)
            if !course.instructor.isEmpty {
                detailRow(label: "Instructor", value: course.instructor)
            }
            detailRow(label: "Credits", value: "\(course.credits)")
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
        .frame(width: 420, height: 320)
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

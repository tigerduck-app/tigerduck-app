import SwiftUI

/// The Add Course filters. On iOS the sheet pushes this page; the Mac shows it in a popover, which
/// cannot push a page, so its pickers are menus and the periods grid sits in the form.
struct CourseSearchFilterView: View {
    @Bindable var model: CourseSearchModel
    let busy: Set<CourseSlot>
    let language: String

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            form
            Divider()
            HStack {
                Spacer()
                resetButton
            }
            .padding(10)
        }
        .frame(width: 420, height: 640)
        #else
        form
            .navigationTitle(String(localized: "course_search_filters"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .primaryAction) { resetButton }
            }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                Toggle(String(localized: "course_search_hide_conflicts"), isOn: $model.filters.hideConflicts)
            }
            Section {
                departmentRow
                levelRow
                dimensionPicker
                #if os(iOS)
                NavigationLink {
                    CoursePeriodsPage(selection: $model.filters.periods, busy: busy)
                } label: {
                    LabeledContent(String(localized: "course_search_periods"), value: periodsText)
                }
                #endif
            }
            #if os(macOS)
            Section(String(localized: "course_search_periods")) {
                CoursePeriodGrid(selection: $model.filters.periods, busy: busy)
                    .frame(height: 380)
                HStack {
                    Button(String(localized: "course_search_clear_periods")) { model.filters.periods = [] }
                        .disabled(model.filters.periods.isEmpty)
                    Spacer()
                    Button(String(localized: "course_search_select_free_periods")) {
                        model.filters.periods = CourseSearch.freeSlots(busy: busy)
                    }
                }
            }
            #endif
            Section {
                Toggle(String(localized: "course_search_general_only"), isOn: $model.filters.generalOnly)
                Toggle(String(localized: "course_search_english_taught"), isOn: $model.filters.englishTaught)
                Toggle(String(localized: "course_search_intensive"), isOn: $model.filters.intensiveOnly)
                Toggle(String(localized: "course_search_exclude_alliance"), isOn: $model.filters.excludeAlliance)
            }
        }
        .formStyle(.grouped)
        // Not `.task`: pushing the department page would cancel the refresh it is waiting for.
        .onAppear { Task { await model.refreshOptions() } }
    }

    private var resetButton: some View {
        Button(String(localized: "course_search_reset_filters")) { model.filters = CourseSearchFilters() }
            .disabled(model.filters.isDefault)
    }

    @ViewBuilder
    private var departmentRow: some View {
        #if os(macOS)
        Picker(String(localized: "course_search_department"), selection: $model.filters.department) {
            Text(String(localized: "course_search_any")).tag(String?.none)
            ForEach(model.options.colleges, id: \.name) { college in
                Section(college.name(in: language)) {
                    ForEach(college.departments, id: \.code) { department in
                        Text(department.name(in: language)).tag(Optional(department.code))
                    }
                }
            }
        }
        #else
        NavigationLink {
            CourseDepartmentPage(
                selection: $model.filters.department,
                colleges: model.options.colleges,
                language: language
            )
        } label: {
            LabeledContent(String(localized: "course_search_department"), value: departmentName)
        }
        #endif
    }

    private var departmentName: String {
        guard let code = model.filters.department else { return String(localized: "course_search_any") }
        let department = model.options.colleges.lazy.flatMap(\.departments).first { $0.code == code }
        return department?.name(in: language) ?? code
    }

    // A long translation moves the segments below the label instead of squeezing them.
    private var levelRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(String(localized: "course_search_level"))
                Spacer()
                levelPicker.fixedSize()
            }
            VStack(alignment: .leading) {
                Text(String(localized: "course_search_level"))
                levelPicker
            }
        }
    }

    private var levelPicker: some View {
        Picker(String(localized: "course_search_level"), selection: $model.filters.level) {
            Text(String(localized: "course_search_level_all")).tag(CourseSearchFilters.Level.all)
            Text(String(localized: "course_search_level_undergraduate")).tag(CourseSearchFilters.Level.undergraduate)
            Text(String(localized: "course_search_level_graduate")).tag(CourseSearchFilters.Level.graduate)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var dimensionPicker: some View {
        Picker(String(localized: "course_search_dimension"), selection: $model.filters.dimension) {
            Text(String(localized: "course_search_any")).tag(String?.none)
            ForEach(model.options.dimensions, id: \.code) { dimension in
                Text(dimension.name(in: language)).tag(Optional(dimension.code))
            }
        }
        #if os(iOS)
        .pickerStyle(.navigationLink)
        #endif
    }

    private var periodsText: String {
        let count = model.filters.periods.count
        return count == 0
            ? String(localized: "course_search_any")
            : String(format: String(localized: "course_search_periods_count"), count)
    }
}

#if os(iOS)
private struct CourseDepartmentPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    let colleges: [CourseSearchOptions.College]
    let language: String
    @State private var query = ""

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                row(nil, name: String(localized: "course_search_any"))
            }
            ForEach(CourseSearch.colleges(colleges, matching: query), id: \.name) { college in
                Section(college.name(in: language)) {
                    ForEach(college.departments, id: \.code) { department in
                        row(department.code, name: department.name(in: language))
                    }
                }
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "action_search")
        )
        .autocorrectionDisabled()
        .textFieldNeverCapitalized()
        .navigationTitle(String(localized: "course_search_department"))
        .inlineNavigationTitle()
    }

    private func row(_ code: String?, name: String) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            HStack {
                Text(name)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if selection == code {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selection == code ? .isSelected : [])
    }
}

private struct CoursePeriodsPage: View {
    @Binding var selection: Set<CourseSlot>
    let busy: Set<CourseSlot>

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            CoursePeriodGrid(selection: $selection, busy: busy)
            Button(String(localized: "course_search_select_free_periods")) {
                selection = CourseSearch.freeSlots(busy: busy)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
        .padding()
        .background(Color.backgroundPrimary)
        .navigationTitle(String(localized: "course_search_periods"))
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "course_search_clear_periods")) { selection = [] }
                    .disabled(selection.isEmpty)
            }
        }
    }
}
#endif

/// Weekdays across, periods down. A drag selects or clears each cell it crosses, as `PeriodDrag`
/// decides, and the periods the timetable already uses are shaded.
struct CoursePeriodGrid: View {
    @Binding var selection: Set<CourseSlot>
    let busy: Set<CourseSlot>

    // Past this size fourteen rows no longer fit a phone screen. The cap sits outside the grid
    // so that its scaled sizes follow it too.
    var body: some View {
        PeriodGridContent(selection: $selection, busy: busy)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

private struct PeriodGridContent: View {
    @Binding var selection: Set<CourseSlot>
    let busy: Set<CourseSlot>
    // Gesture state resets when a drag ends or is cancelled, so no drag decides the next one.
    @GestureState private var drag: PeriodDrag? = nil
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 28
    @ScaledMetric(relativeTo: .caption) private var headerHeight: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var maxCellHeight: CGFloat = 38

    private static let periods = AppConstants.Periods.chronologicalOrder
    private static let captionKeys: [String.LocalizationValue] = [
        "weekday_mon_caption", "weekday_tue_caption", "weekday_wed_caption",
        "weekday_thu_caption", "weekday_fri_caption", "weekday_sat_caption",
    ]

    var body: some View {
        GeometryReader { proxy in
            let cell = CGSize(
                width: (proxy.size.width - labelWidth) / CGFloat(CourseSearch.gridDays.count),
                height: min(maxCellHeight, (proxy.size.height - headerHeight) / CGFloat(Self.periods.count))
            )
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: labelWidth)
                    ForEach(CourseSearch.gridDays, id: \.self) { day in
                        label(AppConstants.Periods.shortWeekdayLabel(day))
                            .frame(width: cell.width)
                    }
                }
                .frame(height: headerHeight)
                .accessibilityHidden(true)
                ForEach(Self.periods, id: \.self) { period in
                    HStack(spacing: 0) {
                        label(period)
                            .frame(width: labelWidth, height: cell.height)
                            .accessibilityHidden(true)
                        ForEach(CourseSearch.gridDays, id: \.self) { day in
                            cellView(CourseSlot(day: day, period: period), size: cell)
                                .frame(width: cell.width, height: cell.height)
                        }
                    }
                }
            }
            .font(TigerDuckTheme.Typography.caption.weight(.semibold))
            .foregroundStyle(Color.textSecondary)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($drag) { value, drag, _ in
                        guard let slot = slot(at: value.location, cell: cell) else { return }
                        var current = drag ?? PeriodDrag()
                        var picked = selection
                        current.touch(slot, in: &picked)
                        drag = current
                        if picked != selection { selection = picked }
                    }
            )
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func cellView(_ slot: CourseSlot, size: CGSize) -> some View {
        let isSelected = selection.contains(slot)
        let fill = isSelected ? Color.accentColor : busy.contains(slot) ? Color.secondary.opacity(0.35) : Color.emptyCellFill
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(fill)
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .frame(width: min(size.width, size.height) * 0.4)
                }
            }
            .padding(2)
            .accessibilityElement()
            .accessibilityLabel("\(String(localized: Self.captionKeys[slot.day - 1])) \(slot.period)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection.formSymmetricDifference([slot]) }
    }

    private func slot(at point: CGPoint, cell: CGSize) -> CourseSlot? {
        guard cell.width > 0, cell.height > 0 else { return nil }
        let column = Int(((point.x - labelWidth) / cell.width).rounded(.down))
        let row = Int(((point.y - headerHeight) / cell.height).rounded(.down))
        guard CourseSearch.gridDays.indices.contains(column), Self.periods.indices.contains(row) else { return nil }
        return CourseSlot(day: CourseSearch.gridDays[column], period: Self.periods[row])
    }
}

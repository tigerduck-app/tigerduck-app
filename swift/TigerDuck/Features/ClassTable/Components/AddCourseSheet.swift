import SwiftUI
import Defaults

struct AddCourseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let semester: String
    let tableCourses: [SDCourse]
    let onAdd: (SDCourse) -> Bool
    var onRemove: ((String) -> Void)? = nil

    private static let liveSearchDebounce: Duration = .milliseconds(350)

    @State private var model = CourseSearchModel()
    @State private var searchText = ""
    @State private var attempt = 0
    @State private var showFilters = false
    @State private var sessionAddedCourseNos: Set<String> = []
    @State private var addingCourseNos: Set<String> = []
    @FocusState private var searchFocused: Bool

    private struct SearchKey: Equatable {
        let text: String
        let filters: CourseSearchFilters
        let attempt: Int
    }

    var body: some View {
        #if os(macOS)
        macBody
            .onAppear { searchFocused = true }
            .task(id: searchKey) { await debouncedSearch() }
        #else
        iosBody
            .onAppear { searchFocused = true }
            .task(id: searchKey) { await debouncedSearch() }
        #endif
    }

    private var searchKey: SearchKey {
        SearchKey(text: trimmedQuery, filters: model.filters.requested, attempt: attempt)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var language: String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    private var table: [CourseSearchTableCourse] {
        tableCourses.map {
            CourseSearchTableCourse(courseNo: $0.courseNo, name: $0.displayName, slots: CourseSearch.slots($0.schedule))
        }
    }

    private var filterSymbol: String {
        model.filters.isDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
    }

    #if !os(macOS)
    private var iosBody: some View {
        NavigationStack {
            let shown = shownCourses
            Form {
                if model.isSearching {
                    Section {
                        HStack(spacing: 8) {
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                            Text(String(localized: "add_course_searching"))
                            Spacer()
                        }
                    }
                }

                if let failureText {
                    Section {
                        Label(failureText, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !shown.isEmpty {
                    Section {
                        resultRows(shown)
                    }
                }
            }
            .overlay {
                emptyState(shown)
                    .allowsHitTesting(false)
            }
            // Dismiss the keyboard from the background only: a `.simultaneousGesture` on
            // the Form swallows row Buttons, so "+" stops firing. Taps in section gaps
            // reach the background; `.scrollDismissesKeyboard` handles drags.
            .background(
                Color.backgroundPrimary
                    .contentShape(Rectangle())
                    .onTapGesture { searchFocused = false }
            )
            .scrollDismissesKeyboard(.interactively)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "add_course_placeholder")
            )
            .searchFocused($searchFocused)
            // The field is active from the start, and active search would otherwise hide the
            // bar that holds Close and the filter button.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .autocorrectionDisabled()
            .textFieldNeverCapitalized()
            .onSubmit(of: .search) { attempt &+= 1 }
            .navigationTitle(String(localized: "add_course_title"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFilters = true
                    } label: {
                        Image(systemName: filterSymbol)
                    }
                    .accessibilityLabel(String(localized: "course_search_filters"))
                }
            }
            .navigationDestination(isPresented: $showFilters) {
                CourseSearchFilterView(model: model, busy: busySlots, language: language)
            }
        }
        // The Form's `.background` paints only the scrollable area, so at the .medium
        // detent the nav bar and bottom safe area stay translucent and the class table
        // shows through. `.presentationBackground` paints the whole sheet container.
        .presentationBackground(Color.backgroundPrimary)
    }

    @ViewBuilder
    private func emptyState(_ shown: [ShownCourse]) -> some View {
        if trimmedQuery.isEmpty {
            ContentUnavailableView(String(localized: "add_course_placeholder"), systemImage: "magnifyingglass")
        } else if model.hasSearched, !model.isSearching, model.failure == nil, shown.isEmpty {
            ContentUnavailableView(String(localized: "add_course_not_found"), systemImage: "magnifyingglass")
        }
    }
    #endif

    #if os(macOS)
    // No `Form`: on macOS it makes the search field tiny. The frame stays modest so the
    // sheet does not dwarf the window.
    private var macBody: some View {
        VStack(spacing: 0) {
            macSearchBar
            Divider()
            macResultsArea
            Divider()
            macBottomBar
        }
        .frame(minWidth: 580, idealWidth: 660, minHeight: 460, idealHeight: 600)
    }

    @ViewBuilder
    private var macSearchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "add_course_title"))
                .font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "add_course_placeholder"), text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { attempt &+= 1 }
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "action_close"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: filterSymbol)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help(String(localized: "course_search_filters"))
                .accessibilityLabel(String(localized: "course_search_filters"))
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    CourseSearchFilterView(model: model, busy: busySlots, language: language)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var macResultsArea: some View {
        let shown = shownCourses
        if model.isSearching && shown.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "add_course_searching"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failureText {
            VStack(spacing: 8) {
                Image(systemName: "xmark.circle")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(failureText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(trimmedQuery.isEmpty
                     ? String(localized: "add_course_placeholder")
                     : String(localized: "add_course_not_found"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                resultRows(shown)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Strip the default macOS bordered-button chrome from each row. Otherwise
            // each result sits in its own rounded button frame, which shifts the leading
            // text edge and makes the course-no / instructor / classroom column uneven.
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var macBottomBar: some View {
        HStack {
            if model.isSearching && !model.results.isEmpty {
                ProgressView().controlSize(.small)
                Text(String(localized: "add_course_searching"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "action_close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    #endif

    private var failureText: String? {
        model.failure.map { String(format: String(localized: "add_course_search_failed"), $0.localizedDescription) }
    }

    private var busySlots: Set<CourseSlot> {
        Set(table.flatMap(\.slots))
    }

    private func debouncedSearch() async {
        let query = trimmedQuery
        guard !query.isEmpty else {
            model.clear()
            return
        }
        try? await Task.sleep(for: Self.liveSearchDebounce)
        guard !Task.isCancelled else { return }
        await model.search(query, semester: semester)
    }

    private struct ShownCourse {
        let course: GroupedCourse
        let conflicts: [String]
    }

    private var shownCourses: [ShownCourse] {
        let table = table
        let filters = model.filters
        return groupedResults.compactMap { course in
            CourseSearch.visibleConflicts(
                courseNo: course.courseNo, schedule: course.schedule, table: table, filters: filters
            ).map { ShownCourse(course: course, conflicts: $0) }
        }
    }

    @ViewBuilder
    private func resultRows(_ shown: [ShownCourse]) -> some View {
        let existingCourseNos = Set(tableCourses.map(\.courseNo))
        ForEach(shown, id: \.course.courseNo) { item in
            let group = item.course
            let isPreExisting = existingCourseNos.contains(group.courseNo)
            let isSessionAdded = sessionAddedCourseNos.contains(group.courseNo)
            let isPresent = isPreExisting || isSessionAdded
            Button {
                if isSessionAdded {
                    sessionAddedCourseNos.remove(group.courseNo)
                    onRemove?(group.courseNo)
                } else if !isPreExisting {
                    addCourse(from: group)
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.displayName)
                            .font(TigerDuckTheme.Typography.headline)
                            .foregroundStyle(Color.textPrimary)
                        Text(String(format: String(localized: "add_course_result_meta"), group.courseNo, group.instructor, group.credits.creditsText))
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(Color.textSecondary)
                        if !group.classroom.isEmpty {
                            Text(group.classroom)
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        if !group.nodeDisplay.isEmpty {
                            Text(group.nodeDisplay)
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        if !isPresent, !item.conflicts.isEmpty {
                            Label(
                                String(
                                    format: String(localized: "course_search_conflicts_with"),
                                    ListFormatter.localizedString(byJoining: item.conflicts)
                                ),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(TigerDuckTheme.Tint.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if isPresent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .disabled(isPreExisting && !isSessionAdded)
        }
    }

    private struct GroupedCourse {
        let courseNo: String
        let primaryName: String
        let secondaryName: String?
        let instructor: String
        let credits: Double
        let classroom: String
        let classroomMap: [String: String]
        let enrolledCount: Int
        let maxCount: Int
        let schedule: [Int: [String]]
        let nodeDisplay: String
        let dimension: String
        let allYear: String
        let requireOption: String

        var displayName: String {
            guard let secondary = secondaryName,
                  !secondary.isEmpty,
                  secondary != primaryName
            else { return primaryName }
            return "\(primaryName) (\(secondary))"
        }
    }

    private var groupedResults: [GroupedCourse] {
        let (rows, secondaryNamesByNo) = CourseSearch.shown(model.results, primary: language)
        var seen: [String: GroupedCourse] = [:]
        var order: [String] = []

        for result in rows {
            let key = result.CourseNo
            let partial = CourseLookupService.parseNodeToSchedule(result.Node)
            var rowSeen = Set<String>()
            let rowRoomParts = SDCourse.splitRoom(result.ClassRoomNo ?? "")
                .filter { rowSeen.insert($0).inserted }
            let rowRoom = rowRoomParts.joined(separator: ", ")

            if var existing = seen[key] {
                var merged = existing.schedule
                for (day, periods) in partial {
                    merged[day, default: []].append(contentsOf: periods)
                }
                let room = (result.ClassRoomNo ?? "").trimmingCharacters(in: .whitespaces)
                let existingRooms = existing.classroom.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let newClassroom = existing.classroom.isEmpty ? room :
                    (room.isEmpty || existingRooms.contains(room)) ? existing.classroom :
                    "\(existing.classroom), \(room)"
                let nodeStr = existing.nodeDisplay.isEmpty ? (result.Node ?? "") :
                    (result.Node == nil || result.Node!.isEmpty) ? existing.nodeDisplay :
                    "\(existing.nodeDisplay), \(result.Node!)"

                var mergedMap = existing.classroomMap
                if !rowRoom.isEmpty {
                    for (day, periods) in partial {
                        for period in periods {
                            mergedMap["\(day)-\(period)"] = rowRoom
                        }
                    }
                }

                existing = GroupedCourse(
                    courseNo: existing.courseNo,
                    primaryName: existing.primaryName,
                    secondaryName: existing.secondaryName,
                    instructor: existing.instructor,
                    credits: existing.credits,
                    classroom: newClassroom,
                    classroomMap: mergedMap,
                    enrolledCount: existing.enrolledCount,
                    maxCount: existing.maxCount,
                    schedule: merged,
                    nodeDisplay: nodeStr,
                    dimension: existing.dimension.isEmpty ? (result.Dimension ?? "") : existing.dimension,
                    allYear: existing.allYear.isEmpty ? (result.AllYear ?? "") : existing.allYear,
                    requireOption: existing.requireOption.isEmpty ? (result.RequireOption ?? "") : existing.requireOption
                )
                seen[key] = existing
            } else {
                var initialMap: [String: String] = [:]
                if !rowRoom.isEmpty {
                    for (day, periods) in partial {
                        for period in periods {
                            initialMap["\(day)-\(period)"] = rowRoom
                        }
                    }
                }
                order.append(key)
                seen[key] = GroupedCourse(
                    courseNo: result.CourseNo,
                    primaryName: result.CourseName,
                    secondaryName: secondaryNamesByNo[result.CourseNo],
                    instructor: result.CourseTeacher,
                    credits: Double(result.CreditPoint) ?? 0,
                    classroom: result.ClassRoomNo ?? "",
                    classroomMap: initialMap,
                    enrolledCount: result.ChooseStudent ?? 0,
                    maxCount: Int(result.Restrict2 ?? "0") ?? 0,
                    schedule: partial,
                    nodeDisplay: result.Node ?? "",
                    dimension: result.Dimension ?? "",
                    allYear: result.AllYear ?? "",
                    requireOption: result.RequireOption ?? ""
                )
            }
        }

        return order.compactMap { seen[$0] }
    }

    private func addCourse(from group: GroupedCourse) {
        // A second tap while the lookup is out would send another lookup and add again.
        guard addingCourseNos.insert(group.courseNo).inserted else { return }
        Task {
            defer { addingCourseNos.remove(group.courseNo) }
            let row = await model.appLanguageRow(of: group.courseNo, language: language, semester: semester)
            add(group, name: row?.CourseName ?? group.primaryName, instructor: row?.CourseTeacher ?? group.instructor)
        }
    }

    private func add(_ group: GroupedCourse, name: String, instructor: String) {
        let course = SDCourse(
            courseNo: group.courseNo,
            courseName: name,
            instructor: instructor,
            credits: group.credits,
            classroom: group.classroom,
            enrolledCount: group.enrolledCount,
            maxCount: group.maxCount,
            schedule: group.schedule,
            moodleIdNumber: nil,
            semester: semester,
            classroomMap: group.classroomMap,
            dimension: group.dimension,
            allYear: group.allYear,
            requireOption: group.requireOption
        )
        if onAdd(course) {
            sessionAddedCourseNos.insert(group.courseNo)
        }
    }
}

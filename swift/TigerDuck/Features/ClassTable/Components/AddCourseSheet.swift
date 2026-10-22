import SwiftUI
import Defaults

struct AddCourseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let semester: String
    let existingCourseNos: Set<String>
    let onAdd: (SDCourse) -> Bool
    var onRemove: ((String) -> Void)? = nil

    private static let courseCodePattern = #"^[A-Za-z0-9]+$"#

    private static let liveSearchDebounce: Duration = .milliseconds(350)

    @State private var searchText = ""
    @State private var submitTrigger: Int = 0
    @State private var primaryResults: [CourseSearchResult] = []
    @State private var secondaryNamesByNo: [String: String] = [:]
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var sessionAddedCourseNos: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        #if os(macOS)
        macBody
            .onAppear { searchFocused = true }
            .task(id: searchText) { await debouncedSearch() }
            .task(id: submitTrigger) { await submitSearch() }
        #else
        iosBody
            .onAppear { searchFocused = true }
            .task(id: searchText) { await debouncedSearch() }
            .task(id: submitTrigger) { await submitSearch() }
        #endif
    }

    private var iosBody: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "add_course_placeholder"), text: $searchText)
                        .autocorrectionDisabled()
                        .textFieldNeverCapitalized()
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { submitTrigger &+= 1 }
                } footer: {
                    Label(String(localized: "add_course_example"), systemImage: "info.circle")
                        .font(.caption)
                }

                if isSearching {
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

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if !primaryResults.isEmpty {
                    Section {
                        resultRows
                    }
                }
            }
            .background(
                Color.backgroundPrimary
                    .contentShape(Rectangle())
                    .onTapGesture { searchFocused = false }
            )
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(String(localized: "add_course_title"))
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
        }
        .presentationBackground(Color.backgroundPrimary)
    }

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
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "add_course_placeholder"), text: $searchText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit { submitTrigger &+= 1 }
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
            Label(String(localized: "add_course_example"), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var macResultsArea: some View {
        if isSearching && primaryResults.isEmpty {
            VStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "add_course_searching"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "xmark.circle")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if primaryResults.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(searchText.trimmingCharacters(in: .whitespaces).isEmpty
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
                resultRows
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var macBottomBar: some View {
        HStack {
            if isSearching && !primaryResults.isEmpty {
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

    private func debouncedSearch() async {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            primaryResults = []
            secondaryNamesByNo = [:]
            errorMessage = nil
            isSearching = false
            return
        }
        try? await Task.sleep(for: Self.liveSearchDebounce)
        if Task.isCancelled { return }
        await runSearch(query: trimmed)
    }

    private func submitSearch() async {
        guard submitTrigger > 0 else { return }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await runSearch(query: trimmed)
    }

    @ViewBuilder
    private var resultRows: some View {
        let grouped = groupedResults
        ForEach(grouped, id: \.courseNo) { group in
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

    @MainActor
    private func runSearch(query: String) async {
        errorMessage = nil
        isSearching = true
        primaryResults = []
        secondaryNamesByNo = [:]

        let isCourseCode = Self.looksLikeCourseCode(query)
        let primaryLanguage = LanguageManager.resolvedCourseApiLanguage(
            appLanguage: Defaults[.appLanguage]
        )
        let zhQuery = Self.toTraditional(query)
        let enQuery = query

        do {
            async let zhTask = Self.fetchResults(
                semester: semester, query: zhQuery, language: "zh", isCourseCode: isCourseCode
            )
            async let enTask = Self.fetchResults(
                semester: semester, query: enQuery, language: "en", isCourseCode: isCourseCode
            )
            let zhResults = try await zhTask
            try Task.checkCancellation()
            let enResults = try await enTask
            try Task.checkCancellation()

            let primaryResultsRaw = primaryLanguage == "en" ? enResults : zhResults
            let secondaryResultsRaw = primaryLanguage == "en" ? zhResults : enResults

            if !primaryResultsRaw.isEmpty {
                primaryResults = primaryResultsRaw
                secondaryNamesByNo = Dictionary(
                    secondaryResultsRaw.map { ($0.CourseNo, $0.CourseName) },
                    uniquingKeysWith: { first, _ in first }
                )
                isSearching = false
                return
            }

            let (zhFilled, enFilled) = await Self.fillCrossLanguage(
                semester: semester, zhResults: zhResults, enResults: enResults
            )
            try Task.checkCancellation()

            let primary = primaryLanguage == "en" ? enFilled : zhFilled
            let secondary = primaryLanguage == "en" ? zhFilled : enFilled
            let secondaryByNo = Dictionary(
                secondary.map { ($0.CourseNo, $0.CourseName) },
                uniquingKeysWith: { first, _ in first }
            )

            primaryResults = primary
            secondaryNamesByNo = secondaryByNo
            isSearching = false
            if primary.isEmpty {
                errorMessage = String(localized: "add_course_not_found")
            }
        } catch is CancellationError {
            return
        } catch {
            AppLogger.captureError(error, context: [
                "feature": "addCourseSheet.search",
                "mode": isCourseCode ? "courseCode" : "nameOrTeacher",
            ])
            isSearching = false
            errorMessage = String(format: String(localized: "add_course_search_failed"), error.localizedDescription)
        }
    }

    private static func fetchResults(
        semester: String, query: String, language: String, isCourseCode: Bool
    ) async throws -> [CourseSearchResult] {
        if isCourseCode {
            return try await CourseLookupService.lookupCourse(
                semester: semester, courseNo: query, language: language, fresh: true
            )
        }
        async let byNameTask = CourseLookupService.searchCourses(
            semester: semester, courseName: query, language: language
        )
        async let byTeacherTask = CourseLookupService.searchByTeacher(
            semester: semester, teacher: query, language: language
        )

        var nameResults: [CourseSearchResult] = []
        var teacherResults: [CourseSearchResult] = []
        var nameError: Error?
        var teacherError: Error?
        do { nameResults = try await byNameTask } catch { nameError = error }
        do { teacherResults = try await byTeacherTask } catch { teacherError = error }

        if let nameError, teacherError != nil {
            throw nameError
        }
        return merge(nameResults, teacherResults)
    }

    private static func fillCrossLanguage(
        semester: String,
        zhResults: [CourseSearchResult],
        enResults: [CourseSearchResult]
    ) async -> ([CourseSearchResult], [CourseSearchResult]) {
        let zhByNo = Set(zhResults.map(\.CourseNo))
        let enByNo = Set(enResults.map(\.CourseNo))
        let missingZh = enByNo.subtracting(zhByNo)
        let missingEn = zhByNo.subtracting(enByNo)

        async let zhExtras: [CourseSearchResult] = withTaskGroup(of: [CourseSearchResult].self) { group in
            for no in missingZh {
                group.addTask {
                    (try? await CourseLookupService.lookupCourse(
                        semester: semester, courseNo: no, language: "zh", fresh: true
                    )) ?? []
                }
            }
            return await group.reduce(into: []) { $0.append(contentsOf: $1) }
        }
        async let enExtras: [CourseSearchResult] = withTaskGroup(of: [CourseSearchResult].self) { group in
            for no in missingEn {
                group.addTask {
                    (try? await CourseLookupService.lookupCourse(
                        semester: semester, courseNo: no, language: "en", fresh: true
                    )) ?? []
                }
            }
            return await group.reduce(into: []) { $0.append(contentsOf: $1) }
        }
        return (zhResults + (await zhExtras), enResults + (await enExtras))
    }

    private static func merge(
        _ primary: [CourseSearchResult],
        _ secondary: [CourseSearchResult]
    ) -> [CourseSearchResult] {
        var seen = Set<String>()
        var merged: [CourseSearchResult] = []
        for result in primary + secondary {
            let key = "\(result.CourseNo)#\(result.Node ?? "")"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(result)
        }
        return merged
    }

    private static func looksLikeCourseCode(_ text: String) -> Bool {
        guard text.range(of: courseCodePattern, options: .regularExpression) != nil else { return false }
        return text.contains(where: { $0.isNumber })
    }

    private static let hansHantTransform = StringTransform(rawValue: "Hans-Hant")

    private static func toTraditional(_ text: String) -> String {
        text.applyingTransform(hansHantTransform, reverse: false) ?? text
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
        var seen: [String: GroupedCourse] = [:]
        var order: [String] = []

        for result in primaryResults {
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
        let course = SDCourse(
            courseNo: group.courseNo,
            courseName: group.primaryName,
            instructor: group.instructor,
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

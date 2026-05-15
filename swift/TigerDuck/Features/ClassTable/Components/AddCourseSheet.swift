import SwiftUI
import Defaults

struct AddCourseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let semester: String
    let existingCourseNos: Set<String>
    let onAdd: (SDCourse) -> Void
    var onRemove: ((String) -> Void)? = nil

    /// Course codes are ASCII alphanumeric and always contain at least one digit
    /// (e.g., "EC1013701", "GE1002101"). Anything else is treated as a name or
    /// teacher query.
    private static let courseCodePattern = #"^[A-Za-z0-9]+$"#

    /// Debounce window before firing an automatic search. Mirrors the Android
    /// AddCourseSheet so the QueryCourse API isn't hammered on every keystroke.
    private static let liveSearchDebounce: Duration = .milliseconds(350)

    @State private var searchText = ""
    @State private var primaryResults: [CourseSearchResult] = []
    @State private var secondaryNamesByNo: [String: String] = [:]
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var sessionAddedCourseNos: Set<String> = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "add_course_placeholder"), text: $searchText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { triggerSearch(debounced: false) }
                        .onChange(of: searchText) { _, _ in triggerSearch(debounced: true) }
                } footer: {
                    Label(String(localized: "add_course_example"), systemImage: "info.circle")
                        .font(.caption)
                }

                if isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView(String(localized: "add_course_searching"))
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
            .background(Color.backgroundPrimary)
            .navigationTitle(String(localized: "add_course_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_close")) { dismiss() }
                }
            }
            .onAppear { searchFocused = true }
        }
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
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.displayName)
                            .font(TigerDuckTheme.Typography.headline)
                            .foregroundStyle(Color.textPrimary)
                        Text(String(format: String(localized: "add_course_result_meta"), group.courseNo, group.instructor, group.credits))
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
                    Spacer()
                    if isPresent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentPrimary)
                    }
                }
            }
            // Pre-existing enrolled courses are not removable from this sheet
            // — the user already has them, and tap-to-remove here would be a
            // dangerous escape hatch. Only courses added in *this* session
            // can be toggled off.
            .disabled(isPreExisting && !isSessionAdded)
        }
    }

    // MARK: - Search dispatch

    private func triggerSearch(debounced: Bool) {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        searchTask?.cancel()

        if trimmed.isEmpty {
            primaryResults = []
            secondaryNamesByNo = [:]
            errorMessage = nil
            isSearching = false
            return
        }

        searchTask = Task {
            if debounced {
                try? await Task.sleep(for: Self.liveSearchDebounce)
                if Task.isCancelled { return }
            }
            await runSearch(query: trimmed)
        }
    }

    @MainActor
    private func runSearch(query: String) async {
        errorMessage = nil
        isSearching = true
        primaryResults = []
        secondaryNamesByNo = [:]

        let isCourseCode = Self.looksLikeCourseCode(query)
        let uiLanguage = LanguageManager.resolvedCourseApiLanguage(
            appLanguage: Defaults[.appLanguage]
        )
        // Send the traditional form to the zh API so simplified queries
        // ("隐私") still match traditional course names ("隱私與資訊安全").
        let zhQuery = Self.toTraditional(query)
        let enQuery = query

        do {
            async let zhTask = Self.fetchResults(
                semester: semester, query: zhQuery, language: "zh", isCourseCode: isCourseCode
            )
            async let enTask = Self.fetchResults(
                semester: semester, query: enQuery, language: "en", isCourseCode: isCourseCode
            )
            let zhResults = await zhTask
            try Task.checkCancellation()
            let enResults = await enTask
            try Task.checkCancellation()

            // The name-search API matches against the queried language only,
            // so searching "隱私" against the EN endpoint returns nothing even
            // when the course exists. Fill any cross-language gaps via the
            // language-agnostic lookupCourse (keyed by code).
            let (zhFilled, enFilled) = await Self.fillCrossLanguage(
                semester: semester, zhResults: zhResults, enResults: enResults
            )
            try Task.checkCancellation()

            // The primary list (what we show + group) comes from the UI
            // language; the secondary map carries the parenthetical name.
            let primary = uiLanguage == "en" ? enFilled : zhFilled
            let secondary = uiLanguage == "en" ? zhFilled : enFilled
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
    ) async -> [CourseSearchResult] {
        if isCourseCode {
            return (try? await CourseLookupService.lookupCourse(
                semester: semester, courseNo: query, language: language
            )) ?? []
        }
        async let byName = (try? CourseLookupService.searchCourses(
            semester: semester, courseName: query, language: language
        )) ?? []
        async let byTeacher = (try? CourseLookupService.searchByTeacher(
            semester: semester, teacher: query, language: language
        )) ?? []
        return merge(await byName, await byTeacher)
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
                        semester: semester, courseNo: no, language: "zh"
                    )) ?? []
                }
            }
            return await group.reduce(into: []) { $0.append(contentsOf: $1) }
        }
        async let enExtras: [CourseSearchResult] = withTaskGroup(of: [CourseSearchResult].self) { group in
            for no in missingEn {
                group.addTask {
                    (try? await CourseLookupService.lookupCourse(
                        semester: semester, courseNo: no, language: "en"
                    )) ?? []
                }
            }
            return await group.reduce(into: []) { $0.append(contentsOf: $1) }
        }
        return (zhResults + (await zhExtras), enResults + (await enExtras))
    }

    /// Merge name and teacher results preserving order; name results come first,
    /// teacher-only results appear after, deduped by `(CourseNo, Node)`.
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

    // MARK: - Heuristics

    private static func looksLikeCourseCode(_ text: String) -> Bool {
        guard text.range(of: courseCodePattern, options: .regularExpression) != nil else { return false }
        return text.contains(where: { $0.isNumber })
    }

    private static let hansHantTransform = StringTransform(rawValue: "Hans-Hant")

    private static func toTraditional(_ text: String) -> String {
        text.applyingTransform(hansHantTransform, reverse: false) ?? text
    }

    // MARK: - Group & Add

    private struct GroupedCourse {
        let courseNo: String
        let primaryName: String
        let secondaryName: String?
        let instructor: String
        let credits: Int
        let classroom: String
        let enrolledCount: Int
        let maxCount: Int
        let schedule: [Int: [String]]
        let nodeDisplay: String

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
            if var existing = seen[key] {
                let partial = CourseLookupService.parseNodeToSchedule(result.Node)
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

                existing = GroupedCourse(
                    courseNo: existing.courseNo,
                    primaryName: existing.primaryName,
                    secondaryName: existing.secondaryName,
                    instructor: existing.instructor,
                    credits: existing.credits,
                    classroom: newClassroom,
                    enrolledCount: existing.enrolledCount,
                    maxCount: existing.maxCount,
                    schedule: merged,
                    nodeDisplay: nodeStr
                )
                seen[key] = existing
            } else {
                order.append(key)
                seen[key] = GroupedCourse(
                    courseNo: result.CourseNo,
                    primaryName: result.CourseName,
                    secondaryName: secondaryNamesByNo[result.CourseNo],
                    instructor: result.CourseTeacher,
                    credits: Int(result.CreditPoint) ?? 0,
                    classroom: result.ClassRoomNo ?? "",
                    enrolledCount: result.ChooseStudent ?? 0,
                    maxCount: Int(result.Restrict2 ?? "0") ?? 0,
                    schedule: CourseLookupService.parseNodeToSchedule(result.Node),
                    nodeDisplay: result.Node ?? ""
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
            moodleIdNumber: nil
        )
        onAdd(course)
        sessionAddedCourseNos.insert(group.courseNo)
    }
}

import SwiftUI
import Defaults

struct AddCourseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let semester: String
    let existingCourseNos: Set<String>
    let onAdd: (SDCourse) -> Void

    /// Course codes are ASCII alphanumeric and always contain at least one digit
    /// (e.g., "EC1013701", "GE1002101"). Anything else is treated as a name or
    /// teacher query.
    private static let courseCodePattern = #"^[A-Za-z0-9]+$"#

    @State private var searchText = ""
    @State private var searchResults: [CourseSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var addedCourseNo: String?
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
                        .onSubmit { search() }
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

                if !searchResults.isEmpty {
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

    private func looksLikeCourseCode(_ text: String) -> Bool {
        guard text.range(of: Self.courseCodePattern, options: .regularExpression) != nil else { return false }
        return text.contains(where: { $0.isNumber })
    }

    @ViewBuilder
    private var resultRows: some View {
        let grouped = groupedResults
        ForEach(grouped, id: \.courseNo) { group in
            let alreadyExists = existingCourseNos.contains(group.courseNo)
                || addedCourseNo == group.courseNo
            Button {
                guard !alreadyExists else { return }
                addCourse(from: group)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.courseName)
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
                    if alreadyExists {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.accentPrimary)
                    }
                }
            }
            .disabled(alreadyExists)
        }
    }

    // MARK: - Search

    private func search() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isSearching = true
        searchResults = []
        addedCourseNo = nil
        searchTask?.cancel()

        let isCourseCode = looksLikeCourseCode(trimmed)

        let language = LanguageManager.resolvedCourseApiLanguage(
            appLanguage: Defaults[.appLanguage]
        )

        searchTask = Task {
            do {
                let results: [CourseSearchResult]
                if isCourseCode {
                    results = try await CourseLookupService.lookupCourse(
                        semester: semester, courseNo: trimmed, language: language
                    )
                } else {
                    async let byName = CourseLookupService.searchCourses(
                        semester: semester, courseName: trimmed, language: language
                    )
                    async let byTeacher = CourseLookupService.searchByTeacher(
                        semester: semester, teacher: trimmed, language: language
                    )
                    let nameResults = (try? await byName) ?? []
                    let teacherResults = (try? await byTeacher) ?? []
                    results = Self.merge(nameResults, teacherResults)
                }
                await MainActor.run {
                    searchResults = results
                    isSearching = false
                    if results.isEmpty {
                        errorMessage = String(localized: "add_course_not_found")
                    }
                }
            } catch {
                AppLogger.captureError(error, context: [
                    "feature": "addCourseSheet.search",
                    "mode": isCourseCode ? "courseCode" : "nameOrTeacher",
                ])
                await MainActor.run {
                    isSearching = false
                    errorMessage = String(format: String(localized: "add_course_search_failed"), error.localizedDescription)
                }
            }
        }
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

    // MARK: - Group & Add

    private struct GroupedCourse {
        let courseNo: String
        let courseName: String
        let instructor: String
        let credits: Int
        let classroom: String
        let enrolledCount: Int
        let maxCount: Int
        let schedule: [Int: [String]]
        let nodeDisplay: String
    }

    private var groupedResults: [GroupedCourse] {
        var seen: [String: GroupedCourse] = [:]
        var order: [String] = []

        for result in searchResults {
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
                    courseName: existing.courseName,
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
                    courseName: result.CourseName,
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
            courseName: group.courseName,
            instructor: group.instructor,
            credits: group.credits,
            classroom: group.classroom,
            enrolledCount: group.enrolledCount,
            maxCount: group.maxCount,
            schedule: group.schedule,
            moodleIdNumber: nil
        )
        onAdd(course)
        addedCourseNo = group.courseNo
    }
}

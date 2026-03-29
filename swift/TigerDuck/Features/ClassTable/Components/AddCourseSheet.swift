import SwiftUI

struct AddCourseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let semester: String
    let existingCourseNos: Set<String>
    let onAdd: (SDCourse) -> Void

    enum SearchMode: String, CaseIterable {
        case courseCode = "課程代碼"
        case courseName = "課名搜尋"
    }

    @State private var searchMode: SearchMode = .courseCode
    @State private var searchText = ""
    @State private var searchResults: [CourseSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var addedCourseNo: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: TigerDuckTheme.Spacing.md) {
                Picker("搜尋方式", selection: $searchMode) {
                    ForEach(SearchMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                HStack(spacing: TigerDuckTheme.Spacing.sm) {
                    TextField(placeholder, text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { search() }

                    Button {
                        search()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentPrimary)
                    .disabled(searchText.isEmpty || isSearching)
                }
                .padding(.horizontal)

                if let errorMessage {
                    Text(errorMessage)
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                if isSearching {
                    Spacer()
                    ProgressView("搜尋中...")
                    Spacer()
                } else if searchResults.isEmpty && addedCourseNo == nil {
                    Spacer()
                    Text("輸入課程代碼或課名後搜尋")
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                } else {
                    resultsList
                }
            }
            .padding(.top, TigerDuckTheme.Spacing.sm)
            .background(Color.backgroundPrimary)
            .navigationTitle("新增課程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
            }
        }
    }

    private var placeholder: String {
        switch searchMode {
        case .courseCode: "例如：EC1013701"
        case .courseName: "例如：微積分"
        }
    }

    private var resultsList: some View {
        let grouped = groupedResults
        return List {
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
                            Text("\(group.courseNo) · \(group.instructor) · \(group.credits)學分")
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
        .listStyle(.plain)
    }

    // MARK: - Search

    private func search() {
        guard !searchText.isEmpty else { return }
        errorMessage = nil
        isSearching = true
        searchResults = []

        Task {
            do {
                let results: [CourseSearchResult]
                switch searchMode {
                case .courseCode:
                    results = try await CourseService.lookupCourse(
                        semester: semester, courseNo: searchText.trimmingCharacters(in: .whitespaces)
                    )
                case .courseName:
                    results = try await CourseService.searchCourses(
                        semester: semester, courseName: searchText.trimmingCharacters(in: .whitespaces)
                    )
                }
                await MainActor.run {
                    searchResults = results
                    isSearching = false
                    if results.isEmpty {
                        errorMessage = "找不到符合的課程"
                    }
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    errorMessage = "搜尋失敗：\(error.localizedDescription)"
                }
            }
        }
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
                let partial = CourseService.parseNodeToSchedule(result.Node)
                var merged = existing.schedule
                for (day, periods) in partial {
                    merged[day, default: []].append(contentsOf: periods)
                }
                let room = result.ClassRoomNo ?? ""
                let newClassroom = existing.classroom.isEmpty ? room :
                    (room.isEmpty || existing.classroom.contains(room)) ? existing.classroom :
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
                    schedule: CourseService.parseNodeToSchedule(result.Node),
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

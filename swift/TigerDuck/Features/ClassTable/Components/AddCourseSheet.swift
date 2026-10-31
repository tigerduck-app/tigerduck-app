import SwiftUI
import Defaults

struct AddCourseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var app

    let semester: String
    let tableCourses: [CourseStore.Course]
    let onAdd: (CourseStore.Course) -> Bool
    var onRemove: ((String) -> Void)? = nil

    @State private var model = CourseSearchModel()
    @State private var searchText = ""
    @State private var showFilters = false
    @State private var sessionAddedCourseNos: Set<String> = []
    @FocusState private var searchFocused: Bool

    private struct SearchKey: Equatable {
        let text: String
        let filters: CourseSearchFilters
        let revision: Int
    }

    var body: some View {
        #if os(macOS)
        AddCourseMacLayout(
            model: model, searchText: $searchText, showFilters: $showFilters, searchFocused: $searchFocused,
            shown: shownCourses, rows: resultRows(shownCourses), failureText: failureText,
            filterSymbol: filterSymbol, busySlots: busySlots, language: language
        )
        .onAppear { searchFocused = true }
        .task(id: searchKey) {
            await model.search(searchText, semester: semester, fetch: fetchCatalog)
        }
        #else
        iosBody
            .onAppear { searchFocused = true }
            .task(id: searchKey) {
                await model.search(searchText, semester: semester, fetch: fetchCatalog)
            }
        #endif
    }

    private var searchKey: SearchKey {
        SearchKey(text: trimmedQuery, filters: model.filters.searched, revision: model.revision)
    }

    private var fetchCatalog: CourseSearchModel.FetchCatalog {
        CourseCatalogStore.fetch(auth: app.authTokenManager.backendAuth)
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
            .onSubmit(of: .search) { model.submit() }
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
    private func emptyState(_ shown: [AddCourseResults.Shown]) -> some View {
        if trimmedQuery.isEmpty {
            ContentUnavailableView(String(localized: "add_course_placeholder"), systemImage: "magnifyingglass")
        } else if model.hasSearched, !model.isSearching, model.failure == nil, shown.isEmpty {
            ContentUnavailableView(String(localized: "add_course_not_found"), systemImage: "magnifyingglass")
        }
    }
    #endif

    private var failureText: String? {
        model.failure.map { String(format: String(localized: "add_course_search_failed"), $0.localizedDescription) }
    }

    private var busySlots: Set<CourseSlot> {
        Set(table.flatMap(\.slots))
    }

    private var shownCourses: [AddCourseResults.Shown] {
        AddCourseResults.shown(model.results, language: language, table: table, filters: model.filters)
    }

    private func resultRows(_ shown: [AddCourseResults.Shown]) -> AddCourseResultRows {
        AddCourseResultRows(
            shown: shown, tableCourses: tableCourses, addedHere: $sessionAddedCourseNos, add: addCourse, remove: onRemove
        )
    }

    private func addCourse(from group: AddCourseResults.Course) {
        let row = model.appLanguageRow(of: group.courseNo, language: language)
        let course = group.tableCourse(
            semester: semester, name: row?.CourseName ?? group.primaryName, instructor: row?.CourseTeacher ?? group.instructor
        )
        if onAdd(course) {
            sessionAddedCourseNos.insert(group.courseNo)
        }
    }
}

/// A result row's mark: in the table already, which this sheet cannot remove; added in this
/// sheet, which a tap removes again; or not added. VoiceOver hears the first as dimmed.
enum AddCourseRowMark {
    case inTable, addedHere, notAdded

    var symbol: String {
        switch self {
        case .inTable: "checkmark"
        case .addedHere: "checkmark.circle.fill"
        case .notAdded: "plus.circle"
        }
    }

    var accessibilityValue: String {
        self == .notAdded ? "" : String(localized: "add_course_added")
    }

    var accessibilityHint: String {
        switch self {
        case .inTable: ""
        case .addedHere: String(localized: "action_remove")
        case .notAdded: String(localized: "action_add")
        }
    }
}

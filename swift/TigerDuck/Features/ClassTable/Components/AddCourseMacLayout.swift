#if os(macOS)
import SwiftUI

struct AddCourseMacLayout: View {
    let model: CourseSearchModel
    @Binding var searchText: String
    @Binding var showFilters: Bool
    let searchFocused: FocusState<Bool>.Binding
    let shown: [AddCourseResults.Shown]
    let rows: AddCourseResultRows
    let failureText: String?
    let filterSymbol: String
    let busySlots: Set<CourseSlot>
    let language: String

    @Environment(\.dismiss) private var dismiss

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    // No `Form`: on macOS it makes the search field tiny.
    var body: some View {
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
                        .focused(searchFocused)
                        .submitLabel(.search)
                        .onSubmit { model.submit() }
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
                rows
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
            Spacer()
            Button(String(localized: "action_close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
#endif

#if os(macOS)
import SwiftUI

struct MacClassTableToolbar: ToolbarContent {
    @Bindable var viewModel: ClassTableViewModel
    let importModel: ClassTableImportModel?
    let studentId: String?
    let shareAvailability: ClassTableShareModel.AvailabilityMemo
    let share: () -> Void
    let requestImport: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker(String(localized: "class_table_semester_picker_label"), selection: $viewModel.currentSemester) {
                ForEach(viewModel.availableSemesters, id: \.self) { code in
                    Text(viewModel.displayLabel(for: code)).tag(code)
                }
            }
            .pickerStyle(.menu)
        }
        if viewModel.shownPerson != nil {
            ToolbarItem(placement: .automatic) {
                otherPersonActions
            }
        } else {
            ToolbarItem(placement: .automatic) {
                Button {
                    viewModel.editor.dialogs.showAddCourse = true
                } label: {
                    // A bare `Label` in a macOS toolbar draws the glyph on a higher baseline than
                    // the title. The HStack matches the semester picker's row geometry, and
                    // `.fixedSize` stops AppKit squeezing it to an icon when the picker widens.
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(String(localized: "add_course_title"))
                    }
                    .fixedSize()
                }
                .help(String(localized: "add_course_title"))
            }
        }
        if viewModel.shownPerson == nil {
            ToolbarItem(placement: .automatic) {
                Button(action: share) {
                    HStack(spacing: 4) {
                        Image(systemName: "qrcode")
                        Text(String(localized: "class_table_share"))
                    }
                    .fixedSize()
                }
                .help(String(localized: "class_table_share"))
                .disabled(!ClassTableShareModel.canShare(
                    studentId: studentId,
                    shownTerm: .init(semester: viewModel.currentSemester, courses: viewModel.courses),
                    semesters: viewModel.availableSemesters,
                    memo: shareAvailability
                ))
            }
        }
        ToolbarItem(placement: .automatic) {
            importButton
        }
    }

    @ViewBuilder
    private var importButton: some View {
        if let importModel, importModel.isUpdating {
            Button {
                importModel.cancel()
            } label: {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "action_cancel"))
                }
                .fixedSize()
            }
            .help(String(localized: "action_cancel"))
        } else {
            Button(action: requestImport) {
                HStack(spacing: 4) {
                    Image(systemName: "qrcode.viewfinder")
                    Text(String(localized: "class_table_import"))
                }
                .fixedSize()
            }
            .help(String(localized: "class_table_import"))
            .disabled(importModel?.isLookingUp == true || importModel?.isReadingImage == true)
        }
    }

    private var otherPersonActions: some View {
        let sections = ClassTableOtherPersonAction.sections
            .map { $0.filter { $0 != .exportScreenshot } }
            .filter { !$0.isEmpty }
        return Menu {
            ForEach(sections, id: \.self) { section in
                Section {
                    ForEach(section, id: \.self) { action in
                        Button(role: action.role) {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: "class_table_more_actions"), systemImage: "ellipsis.circle")
        }
        .help(String(localized: "class_table_more_actions"))
    }

    private func perform(_ action: ClassTableOtherPersonAction) {
        switch action {
        case .exportScreenshot: break
        case .importClassTable: requestImport()
        case .rename: viewModel.people.startRenamingPerson()
        case .deleteUser: viewModel.people.startDeletingPerson()
        }
    }
}
#endif

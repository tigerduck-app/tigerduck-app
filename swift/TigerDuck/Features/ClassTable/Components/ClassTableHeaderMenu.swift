import SwiftUI

struct ClassTableHeaderMenu: View {
    let viewModel: ClassTableViewModel
    let canExportPicture: Bool
    @Binding var export: ClassTableExportState
    @Binding var shareModel: ClassTableShareModel?

    @Environment(AppEnvironment.self) private var app
    @Environment(\.requestClassTableImport) private var requestImport
    @State private var shareAvailability = ClassTableShareModel.AvailabilityMemo()
    // Read here and passed on to the export, whose renderer does not inherit
    // this view's environment.
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        HeaderMenuButton(accessibilityLabel: String(localized: "class_table_more_actions")) {
            if viewModel.shownPerson != nil {
                otherPersonActions
            } else {
                ownActions
            }
        }
    }

    @ViewBuilder
    private var ownActions: some View {
        Section {
            Button {
                viewModel.editor.dialogs.showAddCourse = true
            } label: {
                Label(String(localized: "add_course_title"), systemImage: "plus")
            }
            Button {} label: {
                Label(String(localized: "class_table_subscribe_clubs"), systemImage: "person.2")
            }
            .disabled(true)
        }
        Section {
            Button {
                openShareSheet()
            } label: {
                Label(String(localized: "class_table_share"), systemImage: "qrcode")
            }
            .disabled(export.isExporting || !ClassTableShareModel.canShare(
                studentId: app.authService.storedStudentId,
                shownTerm: .init(semester: viewModel.currentSemester, courses: viewModel.courses),
                semesters: viewModel.availableSemesters,
                memo: shareAvailability
            ))
            Button {
                requestImport()
            } label: {
                Label(String(localized: "class_table_import"), systemImage: "qrcode.viewfinder")
            }
        }
        Section {
            exportButton
        }
        Section {
            Button(role: .destructive) {
                viewModel.editor.dialogs.showResetConfirm = true
            } label: {
                Label(String(localized: "class_table_reset_title"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    private var otherPersonActions: some View {
        ForEach(ClassTableOtherPersonAction.sections, id: \.self) { section in
            Section {
                ForEach(section, id: \.self) { action in
                    if action == .exportScreenshot {
                        exportButton
                    } else {
                        Button(role: action.role) {
                            perform(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            }
        }
    }

    private func perform(_ action: ClassTableOtherPersonAction) {
        switch action {
        case .exportScreenshot: exportScreenshot()
        case .importClassTable: requestImport()
        case .rename: viewModel.people.startRenamingPerson()
        case .deleteUser: viewModel.people.startDeletingPerson()
        }
    }

    private var exportButton: some View {
        Button {
            exportScreenshot()
        } label: {
            Label(String(localized: "class_table_export_screenshot"), systemImage: "square.and.arrow.up")
        }
        .disabled(!canExportPicture || export.isExporting)
    }

    private func exportScreenshot() {
        export.isExporting = true
        Task {
            let url = await ClassTableExporter.render(
                viewModel: viewModel,
                app: app,
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                layoutDirection: layoutDirection,
                legibilityWeight: legibilityWeight,
                differentiateWithoutColor: differentiateWithoutColor
            )
            export.isExporting = false
            if let url {
                export.file = ClassTableExportState.File(url: url)
            } else {
                export.showsFailed = true
            }
        }
    }

    private func openShareSheet() {
        guard let studentId = app.authService.storedStudentId else { return }
        let terms = ClassTableShareModel.terms(
            in: viewModel.availableSemesters,
            shownTerm: .init(semester: viewModel.currentSemester, courses: viewModel.courses)
        )
        guard !terms.isEmpty else { return }
        shareModel = ClassTableShareModel(
            studentId: studentId,
            terms: terms,
            semesterLabel: viewModel.displayLabel(for:)
        )
    }
}

struct ClassTableExportState {
    struct File: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var isExporting = false
    var file: File?
    var showsFailed = false
}

extension View {
    func classTableExportSheets(_ export: Binding<ClassTableExportState>) -> some View {
        sheet(item: export.file) { file in
            ShareSheet(url: file.url)
                .onDisappear { ClassTableExporter.discard(file.url) }
                // The heights UIKit gives the share sheet when it
                // presents one itself.
                .presentationDetents([.medium, .large])
        }
        .alert(String(localized: "class_table_export_failed"), isPresented: export.showsFailed) {
            Button(String(localized: "action_confirm"), role: .cancel) {}
        }
    }
}

import SwiftUI

struct ClassTableSemesterBar: View {
    @Bindable var viewModel: ClassTableViewModel

    @Environment(AppEnvironment.self) private var app
    @Environment(\.isUpdatingImportedClassTable) private var isUpdatingImport

    var body: some View {
        HStack {
            Picker(String(localized: "class_table_semester_picker_label"), selection: $viewModel.currentSemester) {
                ForEach(viewModel.availableSemesters, id: \.self) { code in
                    Text(viewModel.displayLabel(for: code)).tag(code)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()

            ownerLabel
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var ownerLabel: some View {
        if viewModel.people.store.hasImportedClassTables {
            Menu {
                ClassTableSwitcherMenuItems(
                    store: viewModel.people.store,
                    userName: ClassTableSwitcherEntry.userName(studentId: app.authService.storedStudentId)
                )
            } label: {
                HStack(spacing: TigerDuckTheme.Spacing.xs) {
                    Text(creditsLabel)
                    if isUpdatingImport {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                }
                .font(TigerDuckTheme.Typography.body)
            }
            .menuOrder(.fixed)
            .accessibilityLabel(Text("a11y_class_table_switch"))
            .accessibilityValue(Text(creditsLabel))
        } else {
            Text(creditsLabel)
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var creditsLabel: String {
        let credits = String(format: String(localized: "class_table_total_credits_value"), viewModel.grid.totalCredits.creditsText)
        let owner = viewModel.shownPerson?.nickname ?? app.authService.storedStudentId
        guard let owner, !owner.isEmpty else { return credits }
        return "\(owner) · \(credits)"
    }
}

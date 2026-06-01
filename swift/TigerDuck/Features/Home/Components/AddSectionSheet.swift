import SwiftUI

struct AddSectionSheet: View {
    let viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var customTitle = ""

    private var availableBuiltInTypes: [HomeSection.HomeSectionType] {
        let existingTypes = Set(viewModel.sections.map(\.type))
        return [.todayCourses, .upcomingAssignments, .quickWidgets]
            .filter { !existingTypes.contains($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !availableBuiltInTypes.isEmpty {
                    Section(String(localized: "home_builtin_sections")) {
                        ForEach(availableBuiltInTypes, id: \.self) { type in
                            Button {
                                viewModel.addSection(type: type, title: type.defaultTitle)
                                dismiss()
                            } label: {
                                Label(type.defaultTitle, systemImage: type.iconName)
                            }
                        }
                    }
                }

                Section(String(localized: "home_custom_section")) {
                    HStack {
                        TextField(String(localized: "home_section_name"), text: $customTitle)
                        Button {
                            guard !customTitle.isEmpty else { return }
                            viewModel.addSection(type: .custom, title: customTitle)
                            dismiss()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentPrimary)
                        }
                        .disabled(customTitle.isEmpty)
                    }
                }

                Section(String(localized: "home_section_add_quick_features")) {
                    let allWidgetFeatures = viewModel.sections
                        .flatMap(\.widgets)
                        .map(\.feature)
                    let addable = AppFeature.widgetFeatures
                        .filter { !allWidgetFeatures.contains($0) }

                    if addable.isEmpty {
                        Text(String(localized: "home_section_all_widgets_added"))
                            .foregroundStyle(Color.textSecondary)
                    } else {
                        ForEach(addable) { feature in
                            Button {
                                if let target = viewModel.sections.first(where: {
                                    $0.type == .quickWidgets || $0.type == .custom
                                }) {
                                    viewModel.addWidget(to: target.id, feature: feature)
                                }
                                dismiss()
                            } label: {
                                Label(feature.displayName, systemImage: feature.iconName)
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "home_add_section_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { dismiss() }
                }
            }
        }
    }
}

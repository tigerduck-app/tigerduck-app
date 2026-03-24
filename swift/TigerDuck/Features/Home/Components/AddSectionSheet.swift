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
                    Section("內建區塊") {
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

                Section("自訂區塊") {
                    HStack {
                        TextField("區塊名稱", text: $customTitle)
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

                Section("新增快速功能") {
                    let allWidgetFeatures = viewModel.sections
                        .flatMap(\.widgets)
                        .map(\.feature)
                    let addable = AppFeature.widgetFeatures
                        .filter { !allWidgetFeatures.contains($0) }

                    if addable.isEmpty {
                        Text("所有快速功能已添加")
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
            .navigationTitle("新增區塊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

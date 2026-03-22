import SwiftUI

struct WidgetGridEditMode: View {
    @Binding var widgets: [WidgetItem]
    @Binding var isEditing: Bool

    private let availableFeatures: [AppFeature] = [
        .announcements, .freeLunch, .clubs, .emptyClassroom,
        .gpa, .scholarship, .englishVocab,
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                    Text("已添加")
                        .font(TigerDuckTheme.Typography.headline)
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal)

                    WidgetGridView(
                        widgets: $widgets,
                        isEditing: .constant(true),
                        onRemove: { widget in
                            withAnimation(.smoothSpring) {
                                widgets.removeAll { $0.id == widget.id }
                            }
                        }
                    )

                    Text("可添加")
                        .font(TigerDuckTheme.Typography.headline)
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal)

                    let currentFeatures = Set(widgets.map(\.feature))
                    let addable = availableFeatures.filter { !currentFeatures.contains($0) }

                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: TigerDuckTheme.Spacing.md
                    ) {
                        ForEach(addable) { feature in
                            Button {
                                withAnimation(.smoothSpring) {
                                    widgets.append(
                                        WidgetItem(
                                            id: UUID().uuidString,
                                            feature: feature,
                                            size: .small
                                        )
                                    )
                                }
                            } label: {
                                HStack {
                                    Image(systemName: feature.iconName)
                                        .foregroundStyle(Color.accentPrimary)
                                    Text(feature.displayName)
                                        .font(TigerDuckTheme.Typography.body)
                                        .foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.accentPrimary)
                                }
                                .cardPadding()
                                .glassCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                }
                .padding(.vertical)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("編輯 Widget")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        isEditing = false
                    }
                }
            }
        }
    }
}

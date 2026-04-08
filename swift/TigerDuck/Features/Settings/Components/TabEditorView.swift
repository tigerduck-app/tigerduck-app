import SwiftUI

struct TabEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: [AppFeature] = []
    @State private var draggingTab: AppFeature?
    @State private var tabDragLocation: CGPoint = .zero
    @State private var tabFingerOffset: CGSize = .zero
    @State private var tabFrames: [String: CGRect] = [:]

    private let maxTabs = 4

    private var availableFeatures: [AppFeature] {
        AppFeature.pinnableFeatures
            .filter { !tabs.contains($0) }
            .filter { appState.libraryFeatureEnabled || !AppFeature.libraryRelatedFeatures.contains($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.xl) {
                    // Tab bar preview with drag-to-reorder
                    VStack(spacing: TigerDuckTheme.Spacing.md) {
                        Text("拖曳圖示調整順序")
                            .font(TigerDuckTheme.Typography.caption)
                            .foregroundStyle(Color.textSecondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: TigerDuckTheme.Spacing.md) {
                                ForEach(tabs, id: \.self) { feature in
                                    TabPreviewItem(feature: feature, isDragging: draggingTab == feature) {
                                        withAnimation(.smoothSpring) {
                                            tabs.removeAll { $0 == feature }
                                        }
                                    }
                                    .opacity(draggingTab == feature ? 0 : 1)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: TabFrameKey.self,
                                                value: [feature.rawValue: geo.frame(in: .named("tabList"))]
                                            )
                                        }
                                    )
                                    .gesture(
                                        DragGesture(minimumDistance: 1, coordinateSpace: .named("tabList"))
                                            .onChanged { value in
                                                if draggingTab == nil {
                                                    draggingTab = feature
                                                    if let frame = tabFrames[feature.rawValue] {
                                                        tabFingerOffset = CGSize(
                                                            width: value.startLocation.x - frame.midX,
                                                            height: value.startLocation.y - frame.midY
                                                        )
                                                    }
                                                }
                                                tabDragLocation = value.location
                                                reorderTabsIfNeeded(at: value.location)
                                            }
                                            .onEnded { _ in
                                                withAnimation(.smoothSpring) {
                                                    draggingTab = nil
                                                }
                                            }
                                    )
                                }

                                // Fixed "more" tab
                                VStack(spacing: 4) {
                                    Image(systemName: AppFeature.more.iconName)
                                        .font(.title3)
                                    Text(AppFeature.more.displayName)
                                        .font(.caption2)
                                }
                                .foregroundStyle(Color.textSecondary)
                                .frame(width: 56)
                                .opacity(0.5)
                            }
                            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                            .padding(.vertical, TigerDuckTheme.Spacing.md)
                            .coordinateSpace(name: "tabList")
                            .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
                            .overlay {
                                if let dragging = draggingTab {
                                    VStack(spacing: 4) {
                                        Image(systemName: dragging.iconName)
                                            .font(.title3)
                                        Text(dragging.displayName)
                                            .font(.caption2)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(Color.accentPrimary)
                                    .frame(width: 56)
                                    .scaleEffect(1.1)
                                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                                    .position(
                                        x: tabDragLocation.x - tabFingerOffset.width,
                                        y: tabDragLocation.y - tabFingerOffset.height
                                    )
                                    .allowsHitTesting(false)
                                }
                            }
                        }
                        .glassCard()
                        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    }

                    // Available features to add
                    if tabs.count < maxTabs && !availableFeatures.isEmpty {
                        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.md) {
                            Text("可新增的分頁")
                                .font(TigerDuckTheme.Typography.headline)
                                .foregroundStyle(Color.textPrimary)
                                .padding(.horizontal, TigerDuckTheme.Spacing.lg)

                            LazyVGrid(
                                columns: [GridItem(.flexible()), GridItem(.flexible())],
                                spacing: TigerDuckTheme.Spacing.md
                            ) {
                                ForEach(availableFeatures) { feature in
                                    Button {
                                        withAnimation(.smoothSpring) {
                                            tabs.append(feature)
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: feature.iconName)
                                                .foregroundStyle(Color.accentPrimary)
                                                .frame(width: 24)
                                            Text(feature.displayName)
                                                .font(TigerDuckTheme.Typography.body)
                                                .foregroundStyle(Color.textPrimary)
                                                .lineLimit(1)
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
                    }

                    Button("恢復預設") {
                        withAnimation(.smoothSpring) {
                            tabs = AppFeature.defaultTabs
                        }
                    }
                    .foregroundStyle(Color.accentPrimary)
                    .padding(.bottom)
                }
                .padding(.top, TigerDuckTheme.Spacing.lg)
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Tab 編輯器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("套用") {
                        appState.configuredTabs = tabs
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            tabs = appState.configuredTabs.filter { feature in
                appState.libraryFeatureEnabled || !AppFeature.libraryRelatedFeatures.contains(feature)
            }
        }
    }

    // MARK: - Reorder tabs

    private func reorderTabsIfNeeded(at point: CGPoint) {
        guard let dragging = draggingTab,
              let fromIndex = tabs.firstIndex(of: dragging) else { return }

        for (rawValue, frame) in tabFrames where rawValue != dragging.rawValue {
            if frame.contains(point),
               let feature = AppFeature(rawValue: rawValue),
               let toIndex = tabs.firstIndex(of: feature) {
                withAnimation(.smoothSpring) {
                    tabs.move(fromOffsets: IndexSet(integer: fromIndex),
                              toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                }
                return
            }
        }
    }
}

// MARK: - Tab frame tracking

private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Tab preview item

private struct TabPreviewItem: View {
    let feature: AppFeature
    let isDragging: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: feature.iconName)
                .font(.title3)
            Text(feature.displayName)
                .font(.caption2)
                .lineLimit(1)
        }
        .foregroundStyle(Color.accentPrimary)
        .frame(width: 56)
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .red)
                    .font(.caption)
            }
            .offset(x: 4, y: -4)
        }
    }
}

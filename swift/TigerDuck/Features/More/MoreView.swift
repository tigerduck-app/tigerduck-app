import SwiftUI

struct MoreView: View {
    @State private var viewModel = MoreViewModel()
    @State private var showNotImplementedAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    HStack {
                        Text("更多")
                            .font(TigerDuckTheme.Typography.title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if #available(iOS 26, *) {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.title3)
                                    .foregroundStyle(.primary)
                                    .frame(width: 50, height: 50)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.textPrimary)
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.md)

                    ForEach(viewModel.groupedFeatures, id: \.category) { group in
                        FeatureCategorySection(
                            category: group.category,
                            features: group.features,
                            isPinned: viewModel.isPinned,
                            onFeatureTap: { feature in
                                if !feature.isImplemented {
                                    showNotImplementedAlert = true
                                }
                            }
                        )
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .alert("快了快了", isPresented: $showNotImplementedAlert) {
                Button("收到！", role: .cancel) { }
            } message: {
                Text("此功能尚未實現，請進請期待～")
            }
        }
    }
}


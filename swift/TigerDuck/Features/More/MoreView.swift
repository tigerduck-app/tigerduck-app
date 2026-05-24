import SwiftUI

struct MoreView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = MoreViewModel()
    @State private var showNotImplementedAlert = false
    @State private var navigationPath = NavigationPath()

    var body: some View {
        @Bindable var appState = appState
        return NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    HStack(alignment: .top) {
                        Text(String(localized: "feature_more"))
                            .font(TigerDuckTheme.Typography.title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if #available(iOS 26, *) {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.title2)
                                    .foregroundStyle(.primary)
                                    .frame(width: 44, height: 44)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.textPrimary)
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.md)

                    ForEach(viewModel.groupedFeatures.filter { group in
                        group.category != .library || appState.libraryFeatureEnabled
                    }, id: \.category) { group in
                        FeatureCategorySection(
                            category: group.category,
                            features: group.features,
                            onFeatureTap: { feature in
                                if feature.isImplemented {
                                    navigationPath.append(feature)
                                } else {
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
            .notImplementedAlert(isPresented: $showNotImplementedAlert)
            .alert(
                String(localized: "settings_library_feature_disabled_title"),
                isPresented: $appState.pendingLibraryEnablePrompt
            ) {
                Button(String(localized: "settings_acknowledged"), role: .cancel) {}
            } message: {
                Text(String(localized: "settings_library_feature_disabled_message"))
            }
            .navigationDestination(for: AppFeature.self) { feature in
                moreDestination(for: feature)
            }
        }
        // Consume deep-links from callers that can't reach this view's
        // local navigationPath directly (e.g. the flip-to-Library
        // coordinator routing here when Library is enabled but not pinned
        // as a top-level tab). `initial: true` covers cold-launch /
        // tab-switch ordering where the flag is already set by the time
        // the body re-renders.
        .onChange(of: appState.pendingMoreDeepLink, initial: true) { _, new in
            guard let new else { return }
            navigationPath.append(new)
            appState.pendingMoreDeepLink = nil
        }
    }

    @ViewBuilder
    private func moreDestination(for feature: AppFeature) -> some View {
        switch feature {
        case .home: HomeView(embedded: true)
        case .classTable: ClassTableView(embedded: true)
        case .calendar: CalendarTabView(embedded: true)
        case .announcements: BulletinsView(embedded: true)
        case .library: LibraryView(embedded: true)
        case .gpa: ScoreView(embedded: true)
        default: PlaceholderFeatureView(feature: feature)
        }
    }
}


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
            // Features pushed from here match their tab-bar pages: no back chevron, with the escape
            // action in `MoreFeatureDestination`. The nav bar stays for titles and toolbar items.
            // Settings is pushed by its own NavigationLink above, so it keeps its back button.
            .navigationDestination(for: AppFeature.self) { feature in
                MoreFeatureDestination { moreDestination(for: feature) }
            }
        }
        // Deep links from callers that cannot reach `navigationPath`: flip-to-Library when Library
        // is not a tab, or a custom-push tap into Announcements. `initial: true` catches one set
        // before the body renders. The path is replaced, not appended: a link means "go to X".
        .onChange(of: appState.pendingMoreDeepLink, initial: true) { _, new in
            guard let new else { return }
            var path = NavigationPath()
            path.append(new)
            navigationPath = path
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
        #if os(iOS)
        case .schoolMail: SchoolMailView(embedded: true)
        #endif
        case .gpa: ScoreView(embedded: true)
        default: PlaceholderFeatureView(feature: feature)
        }
    }
}

/// Chrome for a feature page pushed from More: no back chevron, so it reads like the same
/// feature reached from the tab bar. Hiding the back button makes stock UIKit disable the edge
/// swipe; it survives only because `Extensions/UINavigationController+Swipeback.swift` re-points
/// the `interactivePopGestureRecognizer` delegate app-wide. Switch Control and VoiceOver users
/// do not go back with that swipe, so `.escape` (VoiceOver's two-finger scrub) is their way back.
/// A wrapper view: `@Environment(\.dismiss)` read in `MoreView` resolves to MoreView, not the page.
/// `dismiss()` rather than trimming `navigationPath`: features push their own destinations with
/// `item:`/`isPresented:`, which never enter the bound path, so editing it could desync the stack.
private struct MoreFeatureDestination<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .navigationBarBackButtonHidden(true)
            .accessibilityAction(.escape) { dismiss() }
    }
}


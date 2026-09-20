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
            // A feature opened from More should read as the same page the
            // user would get by tapping it in the tab bar, so the push
            // chevron goes away. Most of these destinations carry their
            // own in-content title bar and sit under an empty nav bar as
            // a tab root; BulletinsView is the exception, with a real
            // `.navigationTitle` plus toolbar items — dropping the
            // chevron is what makes it match its own tab root too.
            //
            // The bar itself stays, because those titles and toolbar
            // items need it. See `MoreFeatureDestination` below for why
            // the chevron's replacement is an escape action rather than
            // nothing at all.
            //
            // Settings is deliberately untouched: it is pushed by its own
            // NavigationLink in the header above, never through this
            // AppFeature destination, so it keeps its back button.
            .navigationDestination(for: AppFeature.self) { feature in
                MoreFeatureDestination { moreDestination(for: feature) }
            }
        }
        // Consume deep-links from callers that can't reach this view's
        // local navigationPath directly (e.g. the flip-to-Library
        // coordinator routing here when Library is enabled but not pinned
        // as a top-level tab, or a custom-push tap routing into
        // Announcements). `initial: true` covers cold-launch / tab-switch
        // ordering where the flag is already set by the time the body
        // re-renders.
        //
        // We REPLACE the navigation path instead of appending: cross-
        // context deep links mean "go to X", not "push X on top of
        // whatever the user was already viewing in More". Appending was
        // surfacing the target view stacked underneath an unrelated
        // earlier destination, leaving the user with an extra back-tap.
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
        case .gpa: ScoreView(embedded: true)
        default: PlaceholderFeatureView(feature: feature)
        }
    }
}

/// Chrome for a feature page pushed from the More tab: no back chevron, so
/// the page reads like the same feature reached from the tab bar.
///
/// Two things have to hold for that to be safe, and neither is local to
/// this file:
///
/// 1. The left-edge swipe is what replaces the chevron for most users, and
///    it survives `navigationBarBackButtonHidden` only because
///    `Extensions/UINavigationController+Swipeback.swift` re-points the
///    `interactivePopGestureRecognizer` delegate app-wide. Stock UIKit
///    disables that gesture *precisely* when the back button is hidden, so
///    deleting that extension strands users on every destination here —
///    not just on the bulletin detail page its comment names.
/// 2. A screen-edge pan has no Switch Control equivalent and is not how
///    VoiceOver users go back, so the swipe alone would make these pages a
///    dead end for assistive tech. `.escape` restores the route the
///    chevron used to provide — VoiceOver's two-finger scrub lands here.
///
/// This has to be a wrapper `View`: `@Environment(\.dismiss)` read in
/// `MoreView`'s own body resolves to MoreView's dismissal, not the pushed
/// page's. `dismiss()` rather than trimming `navigationPath` on purpose —
/// the features below push their own second-level destinations with
/// `item:`/`isPresented:`, which never enter the bound path, so mutating
/// the path directly could desync the stack.
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


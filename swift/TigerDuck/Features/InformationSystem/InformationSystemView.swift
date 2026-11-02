import SwiftUI

struct InformationSystemView: View {
    var embedded = false

    @Environment(AppEnvironment.self) private var app

    var body: some View {
        if embedded {
            page
        } else {
            NavigationStack { page }
        }
    }

    private var page: some View {
        InformationSystemPage(
            request: request(),
            policy: app.preferences.visualStylePolicy,
            onSignIn: { app.router.presentNTUSTLogin() }
        )
    }

    /// From the Keychain, which reads nothing before the first unlock: the page then asks to
    /// sign in, and `AuthService` reads again once the device unlocks.
    private func request() -> InformationSystemViewModel.Request? {
        guard let studentId = app.authService.storedStudentId, let password = app.authService.storedPassword else {
            return nil
        }
        return .init(
            studentId: studentId,
            password: password,
            language: PortalLanguage(appLanguage: app.preferences.appLanguage),
            signIn: app.authService.session.currentSignIn
        )
    }
}

/// The page itself, which reads nothing from the app's environment.
struct InformationSystemPage: View {
    let request: InformationSystemViewModel.Request?
    let policy: VisualStylePolicy
    let onSignIn: () -> Void

    @State private var viewModel: InformationSystemViewModel
    @Environment(\.openURL) private var openURL

    /// The saved links are there from the first frame: the search drawer starts folded only when
    /// it is attached before the page first shows.
    init(
        request: InformationSystemViewModel.Request?, policy: VisualStylePolicy, onSignIn: @escaping () -> Void,
        store: PortalLinks? = nil
    ) {
        self.request = request
        self.policy = policy
        self.onSignIn = onSignIn
        _viewModel = State(initialValue: InformationSystemViewModel(store: store, showing: request))
    }

    private var signedIn: Bool { request != nil }

    var body: some View {
        Group {
            if signedIn, !viewModel.links.isEmpty {
                list.searchable(text: $viewModel.query, prompt: String(localized: "information_system_search_prompt"))
            } else {
                list
            }
        }
        .toolbar { toolbar }
        .task(id: request) { await viewModel.open(request) }
    }

    private var list: some View {
        List { content }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .navigationTitle(String(localized: "feature_information_system"))
            .refreshable { await viewModel.refresh() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if signedIn {
            #if os(iOS)
            // The shared toolbar capsule would stay on screen while the dot fades on idle.
            if #available(iOS 26, *) {
                ToolbarItem(placement: .topBarTrailing) { statusDot }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { statusDot }
            }
            #else
            ToolbarItem(placement: .primaryAction) { statusDot }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label(String(localized: "desktop_action_refresh"), systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.phase == .loading)
            }
            #endif
        }
    }

    private var statusDot: some View {
        SyncStatusDot(
            status: viewModel.status,
            label: String(localized: "feature_information_system"),
            icon: AppFeature.informationSystem.iconName,
            text: SyncStatusDot.statusText(viewModel.status),
            isLoading: viewModel.phase == .loading,
            lastSynced: viewModel.fetchedAt.map { SyncStatusDot.LastSynced.at($0) } ?? .hidden
        )
    }

    @ViewBuilder
    private var content: some View {
        if !signedIn {
            centered { signInPrompt }
        } else if viewModel.links.isEmpty {
            if case .failed(let message) = viewModel.phase {
                centered {
                    LoadFailureView(title: String(localized: "information_system_load_failed"), message: message) {
                        Task { await viewModel.refresh() }
                    }
                }
            } else {
                centered { ProgressView().padding(.vertical, 60) }
            }
        } else {
            centered { chips.padding(.vertical, TigerDuckTheme.Spacing.sm) }
            let sections = viewModel.sections
            if sections.isEmpty {
                centered { ContentUnavailableView.search(text: viewModel.query) }
            }
            ForEach(sections, id: \.category) { section in
                Section {
                    ForEach(Array(section.links.enumerated()), id: \.offset) { _, link in row(link) }
                } header: {
                    Text(section.category.titleKey)
                }
            }
        }
    }

    @ViewBuilder
    private var signInPrompt: some View {
        #if os(iOS)
        LoginRequiredView(
            layout: .page,
            title: String(localized: "common_not_signed_in"),
            message: String(localized: "common_sign_in_required_feature"),
            onPrimary: onSignIn
        )
        #else
        ContentUnavailableView(
            String(localized: "common_not_signed_in"),
            systemImage: "lock",
            description: Text(String(localized: "common_sign_in_required_feature"))
        )
        #endif
    }

    private var chips: some View {
        let all = (id: "", label: String(localized: "information_system_all_services"))
        let options = [all] + PortalCategory.allCases.map { (id: $0.rawValue, label: String(localized: $0.titleKey)) }
        return FilterChipBar(
            options: options,
            selected: [viewModel.category?.rawValue ?? all.id],
            policy: policy,
            onToggle: { id in
                viewModel.category = id == viewModel.category?.rawValue ? nil : PortalCategory(rawValue: id)
            }
        )
    }

    /// Opens through `openURL`: the TigerDuck browser on the phone, the default browser on the Mac.
    private func row(_ link: PortalLink) -> some View {
        Button {
            openURL(link.url)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Text(link.name)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .listRowBackground(Color.clear)
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}

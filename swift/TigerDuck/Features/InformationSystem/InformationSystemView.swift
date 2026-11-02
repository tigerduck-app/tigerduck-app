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
            signedIn: app.authService.hasStoredCredentials,
            policy: app.preferences.visualStylePolicy,
            onSignIn: { app.router.presentNTUSTLogin() }
        )
    }

    /// Nil before the device's first unlock, when the Keychain reads nothing.
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

struct InformationSystemPage: View {
    let request: InformationSystemViewModel.Request?
    let signedIn: Bool
    let policy: VisualStylePolicy
    let onSignIn: () -> Void

    @State private var viewModel: InformationSystemViewModel
    @State private var demoLink: PortalLink?
    @Environment(\.openURL) private var openURL

    init(
        request: InformationSystemViewModel.Request?, signedIn: Bool, policy: VisualStylePolicy,
        onSignIn: @escaping () -> Void, store: PortalLinks? = nil
    ) {
        self.request = request
        self.signedIn = signedIn
        self.policy = policy
        self.onSignIn = onSignIn
        _viewModel = State(initialValue: InformationSystemViewModel(store: store, showing: request))
    }

    private var access: NTUSTProtectedAccessState {
        NTUSTProtectedAccessState(signedIn: signedIn, isEmpty: viewModel.links.isEmpty)
    }

    var body: some View {
        List { content }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .navigationTitle(String(localized: "feature_information_system"))
            .navigationBarSearch(text: $viewModel.query, prompt: String(localized: "information_system_search_prompt"))
            .refreshable { await viewModel.refresh() }
            .toolbar { toolbar }
            .sheet(item: $demoLink) { DemoPortalSheet(link: $0) }
            .task(id: request) { await viewModel.open(request) }
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
        switch access {
        case .loginRequired:
            centered { signInPrompt }
        case .empty:
            if case .failed(let message) = viewModel.phase {
                centered {
                    LoadFailureView(title: String(localized: "information_system_load_failed"), message: message) {
                        Task { await viewModel.refresh() }
                    }
                }
            } else {
                centered { ProgressView().padding(.vertical, 60) }
            }
        case .content:
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

    private func row(_ link: PortalLink) -> some View {
        Button {
            open(link)
        } label: {
            HStack(spacing: TigerDuckTheme.Spacing.md) {
                Text(link.name)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(link.opens ? Color.textPrimary : Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if link.isCampusOnly {
                    Image(systemName: "graduationcap")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                        .accessibilityLabel(String(localized: "information_system_campus_network_only"))
                }
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .disabled(!link.opens)
        .listRowBackground(Color.clear)
    }

    private func open(_ link: PortalLink) {
        #if os(iOS)
        let browser = InformationSystemViewModel.LinkBrowser.inApp
        #else
        let browser = InformationSystemViewModel.LinkBrowser.system
        #endif
        switch InformationSystemViewModel.target(of: link, isDemo: request?.signIn.isDemo == true, browser: browser) {
        case .address(let url): openURL(url)
        case .demoPage(let link): demoLink = link
        }
    }

    private func centered(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }
}

/// A demo link's page on the Mac, whose links open in the default browser, outside the app.
private struct DemoPortalSheet: View {
    let link: PortalLink

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Text(link.category.titleKey)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
            Text(link.name)
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
            Button(String(localized: "action_close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(.top, TigerDuckTheme.Spacing.md)
        }
        .padding(TigerDuckTheme.Spacing.xl)
        .frame(minWidth: 320)
    }
}

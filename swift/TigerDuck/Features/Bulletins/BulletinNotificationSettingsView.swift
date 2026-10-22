import Defaults
import SwiftUI
import UserNotifications

struct BulletinNotificationSettingsView: View {
    let taxonomy: BulletinTaxonomyStore

    @Environment(AppState.self) private var appState
    @State private var store = BulletinSubscriptionsStore()
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var isAskingPermission: Bool = false
    @State private var isDisablingPush: Bool = false
    @State private var pushUpdateFailed: Bool = false
    @State private var editingClientId: UUID?
    @State private var draftRule: BulletinAPI.SubscriptionRule?
    @State private var saveErrorMessage: String?
    @State private var didInitialLoad: Bool = false

    @Default(.bulletinPushEnabled) private var pushEnabled

    var body: some View {
        List {
            pushStatusSection

            if pushEnabled {
                rulesSection
                if store.loadState == .loaded, store.pending.isEmpty {
                    defaultRuleBanner
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "bulletin_notifications_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.configure(authTokenManager: appState.authTokenManager)
            await taxonomy.loadIfNeeded()
            await refreshAuthStatus()
            if pushEnabled, !didInitialLoad {
                didInitialLoad = true
                await store.load()
            }
        }
        .onDisappear {
            // Auto-save on leaving the page (swipe back, tab switch). Pushing the editor also
            // fires `onDisappear`; a non-nil `editingClientId` means the page is only covered.
            if editingClientId == nil, store.isDirty {
                Task { await store.save() }
            }
        }
        .onChange(of: store.saveState) { _, newState in
            if case .failed(let msg) = newState {
                saveErrorMessage = msg
            }
        }
        .alert(
            String(localized: "bulletin_save_failed_title"),
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil; store.clearSaveState() } }
            ),
            actions: { Button(String(localized: "settings_acknowledged"), role: .cancel) {} },
            message: {
                if let msg = saveErrorMessage { Text(msg) }
            }
        )
        .navigationDestination(item: $editingClientId) { clientId in
            ruleEditor(for: clientId)
        }
    }

    @ViewBuilder
    private var pushStatusSection: some View {
        if pushEnabled {
            Section {
                LabeledContent {
                    Text(authStatusText)
                        .foregroundStyle(authStatusColor)
                        .font(.caption)
                } label: {
                    Label(String(localized: "bulletin_push_status_label"), systemImage: "bell.fill")
                }

                if authStatus == .denied {
                    Button {
                        openAppSettings()
                    } label: {
                        Label(String(localized: "bulletin_push_reopen_settings"), systemImage: "gear")
                    }
                }

                Button(role: .destructive) {
                    Task { await disablePush() }
                } label: {
                    LoadingButtonLabel(isLoading: isDisablingPush) {
                        Label(String(localized: "bulletin_push_disable_action"), systemImage: "bell.slash")
                    }
                }
                .disabled(isDisablingPush)
            } header: {
                Text(String(localized: "bulletin_push_settings_header"))
            } footer: {
                if pushUpdateFailed {
                    Text(String(localized: "settings_server_push_update_failed"))
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text(String(localized: "bulletin_push_enable_description"))
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text(String(localized: "bulletin_push_content_description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await enablePush() }
                } label: {
                    LoadingButtonLabel(isLoading: isAskingPermission) {
                        Label(String(localized: "bulletin_push_enable_action"), systemImage: "bell.badge")
                    }
                }
                .disabled(isAskingPermission)

                if Self.requiresSystemSettingsRoute(for: authStatus) {
                    Button {
                        openAppSettings()
                    } label: {
                        Label(String(localized: "bulletin_push_reopen_settings"), systemImage: "gear")
                    }
                }
            } header: {
                Text(String(localized: "bulletin_push_settings_header"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if Self.requiresSystemSettingsRoute(for: authStatus) {
                        Text(String(localized: "permission_not_granted_tap_settings"))
                            .foregroundStyle(.orange)
                    }
                    Text(String(localized: "bulletin_push_footer"))
                    if pushUpdateFailed {
                        Text(String(localized: "settings_server_push_update_failed"))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            switch store.loadState {
            case .idle, .loading:
                HStack(spacing: TigerDuckTheme.Spacing.xs) {
                    ProgressView()
                    Text(String(localized: "bulletin_rules_load_loading")).foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text(String(localized: "bulletin_rules_load_failed")).foregroundStyle(.primary)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button(String(localized: "action_retry")) {
                        Task { await store.load() }
                    }
                    .buttonStyle(.bordered)
                }
            case .loaded:
                ForEach(store.pending, id: \.clientId) { rule in
                    Button {
                        editingClientId = rule.clientId
                    } label: {
                        ruleRow(rule)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: deleteRules)

                Button {
                    let draft = store.makeNewRule()
                    draftRule = draft
                    editingClientId = draft.clientId
                } label: {
                    Label(String(localized: "bulletin_rule_add_action"), systemImage: "plus")
                }
            }
        } header: {
            Text(String(localized: "bulletin_rules_header"))
        } footer: {
            Text(String(localized: "bulletin_rules_footer"))
        }
    }

    private var defaultRuleBanner: some View {
        Section {
            Button {
                if let tax = taxonomy.state.taxonomy {
                    store.seedDefault(from: tax)
                    Task { await store.save() }
                }
            } label: {
                Label(String(localized: "bulletin_apply_default_rules_action"), systemImage: "wand.and.stars")
            }
        } footer: {
            Text(String(localized: "bulletin_default_rules_footer"))
        }
    }

    @ViewBuilder
    private func ruleEditor(for clientId: UUID) -> some View {
        if let existing = store.pending.first(where: { $0.clientId == clientId }) {
            SubscriptionRuleEditorView(
                rule: existing,
                taxonomy: taxonomy,
                onCommit: { updated in
                    store.upsert(updated)
                    Task { await store.save() }
                },
                onDelete: {
                    store.removeRule(clientId: clientId)
                    Task { await store.save() }
                }
            )
        } else if let draft = draftRule, draft.clientId == clientId {
            SubscriptionRuleEditorView(
                rule: draft,
                taxonomy: taxonomy,
                onCommit: { updated in
                    store.upsert(updated)
                    draftRule = nil
                    Task { await store.save() }
                },
                onDelete: nil
            )
        } else {
            Color.clear
                .onAppear { editingClientId = nil }
        }
    }

    private func ruleRow(_ rule: BulletinAPI.SubscriptionRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.name?.nilIfEmpty ?? defaultRuleTitle(rule))
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                if !rule.enabled {
                    Text(String(localized: "bulletin_rule_disabled_badge"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
            Text(ruleSubtitle(rule))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
    }

    private func deleteRules(at offsets: IndexSet) {
        for index in offsets {
            let rule = store.pending[index]
            store.removeRule(clientId: rule.clientId)
        }
        Task { await store.save() }
    }

    private func enablePush() async {
        isAskingPermission = true
        defer { isAskingPermission = false }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthStatus()
        guard granted || authStatus == .provisional else { return }
        do {
            try await appState.updateBulletinPushEnabled(true)
            pushUpdateFailed = false
        } catch {
            pushUpdateFailed = true
            return
        }
        if !didInitialLoad {
            didInitialLoad = true
            await store.load()
        }
    }

    private func disablePush() async {
        isDisablingPush = true
        defer { isDisablingPush = false }
        do {
            try await appState.updateBulletinPushEnabled(false)
            pushUpdateFailed = false
        } catch {
            pushUpdateFailed = true
        }
    }

    private func refreshAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authStatus = settings.authorizationStatus
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Whether the off-state section must explain the permission problem and offer iOS Settings,
    /// instead of leaving "Turn on bulletin push" as the only control. `.denied` is the one status
    /// the enable button cannot move: iOS never re-prompts after a refusal, so
    /// `requestAuthorization` returns `false` silently and `enablePush()` stops at its guard. The
    /// on-state branch's status row and Settings button are unreachable from here, so this section
    /// carries both. An unknown future status errs toward the route, matching
    /// `NotificationPermissionSettingsView.notificationPermissionStatus(for:)`, which maps it to
    /// `.notGranted`. `static` over a plain value so a test needs no view or `AppState`.
    static func requiresSystemSettingsRoute(for status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .denied: return true
        case .authorized, .provisional, .ephemeral, .notDetermined: return false
        @unknown default: return true
        }
    }

    private var authStatusText: String {
        switch authStatus {
        case .authorized: return String(localized: "permission_granted")
        case .provisional: return String(localized: "bulletin_push_status_provisional")
        case .denied: return String(localized: "bulletin_push_status_denied")
        case .notDetermined: return String(localized: "bulletin_push_status_undetermined")
        case .ephemeral: return String(localized: "bulletin_push_status_ephemeral")
        @unknown default: return String(localized: "bulletin_push_status_unknown")
        }
    }

    private var authStatusColor: Color {
        switch authStatus {
        case .authorized, .provisional: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private func defaultRuleTitle(_ rule: BulletinAPI.SubscriptionRule) -> String {
        if rule.orgs.isEmpty, rule.tags.isEmpty { return String(localized: "bulletin_rule_all_title") }
        if !rule.orgs.isEmpty, !rule.tags.isEmpty {
            return String(format: String(localized: "bulletin_rule_dept_and_tag_title"), rule.mode.displayName)
        }
        if !rule.orgs.isEmpty { return String(localized: "bulletin_rule_dept_only_title") }
        return String(localized: "bulletin_rule_tag_only_title")
    }

    private func ruleSubtitle(_ rule: BulletinAPI.SubscriptionRule) -> String {
        let separator = String(localized: "bulletin_rule_filter_separator")
        let orgText = rule.orgs.isEmpty
            ? String(localized: "bulletin_rule_all_depts")
            : String(localized: "bulletin_rule_dept_prefix") + rule.orgs.map { taxonomy.orgLabel(for: $0) }.joined(separator: separator)
        let tagText = rule.tags.isEmpty
            ? String(localized: "bulletin_rule_all_tags")
            : String(localized: "bulletin_rule_tags_prefix") + rule.tags.map { taxonomy.tagLabel(for: $0) }.joined(separator: separator)
        let joiner = rule.mode == .and
            ? String(localized: "bulletin_rule_join_and")
            : String(localized: "bulletin_rule_join_or")
        return orgText + joiner + tagText
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

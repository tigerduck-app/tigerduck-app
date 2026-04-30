import Defaults
import SwiftUI
import UserNotifications

/// Per-device bulletin notification settings.
///
/// Three responsibilities:
/// 1. Surface the OS push permission state and let the user request it.
/// 2. Toggle our `pushServerEnabled` flag (a `Defaults` key); flipping it
///    on triggers `PushCoordinator` registration, off tells the server
///    to drop this device.
/// 3. CRUD the device's subscription rules. There is no manual 儲存
///    button — the page auto-persists in three situations:
///    * on editor 完成 (upsert + save)
///    * on editor 刪除規則 (remove + save)
///    * on page `.onDisappear` if any unsaved change remains (catches
///      swipe-to-delete on the list that didn't route through the
///      editor). The user's mental model is "I tweaked something, I
///      swipe back, it's saved" — matches the Settings / Notes app
///      idiom.
///
/// Tapping 新增規則 does NOT mutate `pending` — the new rule starts life
/// as a local draft held in view state and only enters the server-bound
/// list when the user taps 完成 in the editor. Swiping back out of the
/// editor discards the draft cleanly.
struct BulletinNotificationSettingsView: View {
    let taxonomy: BulletinTaxonomyStore

    @Environment(AppState.self) private var appState
    @State private var store = BulletinSubscriptionsStore()
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var isAskingPermission: Bool = false
    @State private var editingClientId: UUID?
    /// Unpersisted rule that lives only while the editor is on screen.
    /// Transitions to `store.pending` via `upsert` when the user taps
    /// 完成. Replaced (or cleared) whenever the user navigates back out.
    @State private var draftRule: BulletinAPI.SubscriptionRule?
    @State private var saveErrorMessage: String?
    /// Ensures the initial network load fires exactly once per view
    /// instance. Without this guard, SwiftUI's `.task` re-firing on
    /// view re-appearance can issue a redundant GET /subscriptions
    /// right after the user edits — which in the previous iteration
    /// clobbered the user's in-flight pending array.
    @State private var didInitialLoad: Bool = false

    @Default(.pushServerEnabled) private var pushEnabled

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
            // Taxonomy + auth status refresh every time; only the
            // subscription GET is gated so it doesn't re-fire on
            // re-appearance.
            await taxonomy.loadIfNeeded()
            await refreshAuthStatus()
            if pushEnabled, !didInitialLoad {
                didInitialLoad = true
                await store.load()
            }
        }
        .onDisappear {
            // Auto-save when leaving the page (swipe back, tab switch,
            // etc.). Guard against pushing the editor onto the stack —
            // that also fires `onDisappear`, but `editingClientId`
            // tells us we're just being covered, not popped.
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

    // MARK: - Sections

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
                        Label(String(localized: "bulletin_push_reopen_ios_settings"), systemImage: "gear")
                    }
                }

                Button(role: .destructive) {
                    Task { await disablePush() }
                } label: {
                    Label(String(localized: "bulletin_push_disable_action"), systemImage: "bell.slash")
                }
            } header: {
                Text(String(localized: "bulletin_push_settings_header"))
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
                    if isAskingPermission {
                        HStack(spacing: TigerDuckTheme.Spacing.xs) {
                            ProgressView()
                            Text(String(localized: "bulletin_push_requesting"))
                        }
                    } else {
                        Label(String(localized: "bulletin_push_enable_action"), systemImage: "bell.badge")
                    }
                }
                .disabled(isAskingPermission)
            } header: {
                Text(String(localized: "bulletin_push_settings_header"))
            } footer: {
                Text(String(localized: "bulletin_push_footer"))
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
                    // Create a draft rule locally; don't touch `pending`
                    // until 完成. Setting both state fields in the same
                    // tick so SwiftUI batches a single render pass.
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

    // MARK: - Editor routing

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
            // New rule path — the draft lives in view state until
            // 完成 upgrades it into `pending`. Swiping back discards
            // (the editingClientId binding flips to nil, draft remains
            // in state but is simply replaced on the next 新增規則).
            // No onDelete here: there's nothing on the server to
            // delete and the swipe-back gesture is the discard.
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
            // Neither pending nor draft — rule vanished under us
            // (e.g. swipe-delete on a different path). Pop back.
            Color.clear
                .onAppear { editingClientId = nil }
        }
    }

    // MARK: - Row rendering

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

    // MARK: - Actions

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
        appState.enablePushServer()
        if !didInitialLoad {
            didInitialLoad = true
            await store.load()
        }
    }

    private func disablePush() async {
        await appState.disablePushServer()
        // pushEnabled flips reactively via @Default; no manual refresh.
    }

    private func refreshAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authStatus = settings.authorizationStatus
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Text helpers

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
            ? String(localized: "bulletin_rule_all_orgs")
            : String(localized: "bulletin_rule_orgs_prefix") + rule.orgs.map { taxonomy.orgLabel(for: $0) }.joined(separator: separator)
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

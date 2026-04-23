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
/// 3. CRUD the device's subscription rules. Rules are local drafts until
///    the user hits 儲存 — the backend takes a snapshot replacement PUT.
///
/// `@Default(.pushServerEnabled)` gives us a reactive binding so the page
/// updates immediately when push is toggled (the previous read-once
/// `Defaults[.pushServerEnabled]` left the page stale until the next nav
/// event). Rule edits use programmatic navigation via
/// `.navigationDestination(item:)` so the new-rule flow doesn't depend on
/// captured-closure state in a NavigationLink trailing-builder.
struct BulletinNotificationSettingsView: View {
    let taxonomy: BulletinTaxonomyStore

    @Environment(AppState.self) private var appState
    @State private var store = BulletinSubscriptionsStore()
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var isAskingPermission: Bool = false
    @State private var editingClientId: UUID?
    @State private var saveErrorMessage: String?

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
        .navigationTitle("公告通知")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if pushEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    saveToolbarButton
                }
            }
        }
        .task {
            await taxonomy.loadIfNeeded()
            await refreshAuthStatus()
            if pushEnabled {
                await store.load()
            }
        }
        .onChange(of: pushEnabled) { _, isOn in
            // Toggling push back on (e.g. via Settings page elsewhere)
            // should re-load subscriptions so the rules section is
            // populated rather than blank.
            if isOn { Task { await store.load() } }
        }
        .onChange(of: store.saveState) { _, newState in
            if case .failed(let msg) = newState {
                saveErrorMessage = msg
            }
        }
        .alert(
            "儲存失敗",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil; store.clearSaveState() } }
            ),
            actions: { Button("知道了", role: .cancel) {} },
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
                    Label("推播通知", systemImage: "bell.fill")
                }

                if authStatus == .denied {
                    Button {
                        openAppSettings()
                    } label: {
                        Label("在 iOS 設定中重新開啟", systemImage: "gear")
                    }
                }

                Button(role: .destructive) {
                    Task { await disablePush() }
                } label: {
                    Label("關閉公告推播", systemImage: "bell.slash")
                }
            } header: {
                Text("推播設定")
            }
        } else {
            Section {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text("開啟推播後，當有符合你設定規則的公告時，老虎鴨會即時通知你。")
                        .font(.callout)
                        .foregroundStyle(.primary)
                    Text("通知會包含標題與摘要，點開後可直接看到原文。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await enablePush() }
                } label: {
                    if isAskingPermission {
                        HStack(spacing: TigerDuckTheme.Spacing.xs) {
                            ProgressView()
                            Text("請求中…")
                        }
                    } else {
                        Label("開啟公告推播", systemImage: "bell.badge")
                    }
                }
                .disabled(isAskingPermission)
            } header: {
                Text("推播設定")
            } footer: {
                Text("推播通知由 TigerDuck 伺服器根據你選的規則派送。設備標識以匿名 UUID 傳送，不會上傳學號。")
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
                    Text("載入規則…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text("載入失敗").foregroundStyle(.primary)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("重試") {
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
                    let newId = store.addRule()
                    // Defer one runloop so SwiftUI commits the ForEach
                    // append before pushing — without this, the editor
                    // would resolve the rule lookup against pre-append
                    // state on some iOS builds.
                    DispatchQueue.main.async {
                        editingClientId = newId
                    }
                } label: {
                    Label("新增規則", systemImage: "plus")
                }
            }
        } header: {
            Text("通知規則")
        } footer: {
            Text("每條規則可選處室、類別與組合模式。留空代表該維度不篩選。最多 32 條。")
        }
    }

    private var defaultRuleBanner: some View {
        Section {
            Button {
                if let tax = taxonomy.state.taxonomy {
                    store.seedDefault(from: tax)
                }
            } label: {
                Label("套用預設規則", systemImage: "wand.and.stars")
            }
        } footer: {
            Text("預設會訂閱：免費便當、獎助學金、繳費、考試、維修。")
        }
    }

    // MARK: - Toolbar / editor

    @ViewBuilder
    private var saveToolbarButton: some View {
        switch store.saveState {
        case .saving:
            ProgressView()
        default:
            Button("儲存") {
                Task { await store.save() }
            }
            .disabled(store.pending.count > 32)
        }
    }

    @ViewBuilder
    private func ruleEditor(for clientId: UUID) -> some View {
        if let rule = store.pending.first(where: { $0.clientId == clientId }) {
            SubscriptionRuleEditorView(
                rule: rule,
                taxonomy: taxonomy,
                onCommit: { updated in store.update(updated) },
                onDelete: { store.removeRule(clientId: clientId) }
            )
        } else {
            // Rule was deleted while the editor was open (e.g. via swipe
            // on a different navigation path). Bounce back rather than
            // showing a stale view.
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
                    Text("已停用")
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
    }

    private func enablePush() async {
        isAskingPermission = true
        defer { isAskingPermission = false }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthStatus()
        guard granted || authStatus == .provisional else { return }
        appState.enablePushServer()
        await store.load()
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
        case .authorized: return "已允許"
        case .provisional: return "寧靜通知"
        case .denied: return "已被拒絕"
        case .notDetermined: return "尚未決定"
        case .ephemeral: return "臨時"
        @unknown default: return "未知"
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
        if rule.orgs.isEmpty, rule.tags.isEmpty { return "全部公告" }
        if !rule.orgs.isEmpty, !rule.tags.isEmpty { return "處室 + 類別 (\(rule.mode.displayName))" }
        if !rule.orgs.isEmpty { return "指定處室" }
        return "指定類別"
    }

    private func ruleSubtitle(_ rule: BulletinAPI.SubscriptionRule) -> String {
        let orgText = rule.orgs.isEmpty
            ? "全部處室"
            : "處室：" + rule.orgs.map { taxonomy.orgLabel(for: $0) }.joined(separator: "、")
        let tagText = rule.tags.isEmpty
            ? "全部類別"
            : "類別：" + rule.tags.map { taxonomy.tagLabel(for: $0) }.joined(separator: "、")
        let joiner = rule.mode == .and ? " 且 " : " 或 "
        return orgText + joiner + tagText
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

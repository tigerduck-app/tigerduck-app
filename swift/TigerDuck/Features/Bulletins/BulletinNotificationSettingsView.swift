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
        .navigationTitle("公告通知")
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
                    // Create a draft rule locally; don't touch `pending`
                    // until 完成. Setting both state fields in the same
                    // tick so SwiftUI batches a single render pass.
                    let draft = store.makeNewRule()
                    draftRule = draft
                    editingClientId = draft.clientId
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
                    Task { await store.save() }
                }
            } label: {
                Label("套用預設規則", systemImage: "wand.and.stars")
            }
        } footer: {
            Text("預設會訂閱：免費便當、獎助學金、繳費、考試、維修。")
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

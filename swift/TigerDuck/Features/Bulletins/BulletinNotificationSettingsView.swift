import Defaults
import SwiftUI
import UserNotifications

/// Per-device bulletin notification settings.
///
/// Contextual permission: we ask for `UNAuthorizationOptions` the first
/// time the user reaches this page. Turning push on here also flips the
/// app-wide `pushServerEnabled` flag so APNs device-token upload happens
/// automatically via `PushCoordinator`.
///
/// Rules are editable drafts until the user hits 儲存 — a single snapshot
/// PUT replaces the whole set on the server, matching the backend's
/// idempotent replacement contract.
struct BulletinNotificationSettingsView: View {
    let taxonomy: BulletinTaxonomyStore

    @Environment(AppState.self) private var appState
    @State private var store = BulletinSubscriptionsStore()
    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var isAskingPermission: Bool = false

    var body: some View {
        List {
            pushStatusSection

            if Defaults[.pushServerEnabled] {
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
            if Defaults[.pushServerEnabled] {
                ToolbarItem(placement: .primaryAction) {
                    saveButton
                }
            }
        }
        .task {
            await taxonomy.loadIfNeeded()
            await refreshAuthStatus()
            if Defaults[.pushServerEnabled] {
                await store.load()
            }
        }
        .alert(
            "儲存失敗",
            isPresented: Binding(
                get: { if case .failed = store.saveState { return true } else { return false } },
                set: { newValue in if !newValue { store.pending = store.pending } }
            ),
            actions: {
                Button("知道了", role: .cancel) { }
            },
            message: {
                if case .failed(let message) = store.saveState {
                    Text(message)
                }
            }
        )
    }

    // MARK: - Sections

    @ViewBuilder
    private var pushStatusSection: some View {
        Section {
            if Defaults[.pushServerEnabled] {
                HStack {
                    Label("推播通知", systemImage: "bell.fill")
                    Spacer()
                    Text(authStatusText)
                        .foregroundStyle(authStatusColor)
                        .font(.caption)
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
            } else {
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
                        HStack {
                            ProgressView()
                            Text("請求中…")
                        }
                    } else {
                        Label("開啟公告推播", systemImage: "bell.badge")
                    }
                }
                .disabled(isAskingPermission)
            }
        } header: {
            Text("推播設定")
        } footer: {
            if !Defaults[.pushServerEnabled] {
                Text("推播通知由 TigerDuck 伺服器根據你選的規則派送。設備標識以匿名 UUID 傳送，不會上傳學號。")
            }
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            switch store.loadState {
            case .idle, .loading:
                HStack {
                    ProgressView()
                    Text("載入規則…")
                        .foregroundStyle(.secondary)
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
                    NavigationLink {
                        SubscriptionRuleEditorView(
                            rule: rule,
                            taxonomy: taxonomy,
                            onCommit: { store.update($0) },
                            onDelete: { store.removeRule(clientId: rule.clientId) }
                        )
                    } label: {
                        ruleRow(rule)
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let rule = store.pending[index]
                        store.removeRule(clientId: rule.clientId)
                    }
                }

                NavigationLink {
                    SubscriptionRuleEditorView(
                        rule: BulletinAPI.SubscriptionRule(),
                        taxonomy: taxonomy,
                        onCommit: { newRule in
                            store.pending.append(newRule)
                        },
                        onDelete: nil
                    )
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
            Text("預設會訂閱：重要公告、獎學金、繳費、考試、場館與免費便當。")
        }
    }

    // MARK: - Pieces

    private func ruleRow(_ rule: BulletinAPI.SubscriptionRule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.name ?? defaultRuleTitle(rule))
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
    }

    private var saveButton: some View {
        Group {
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
    }

    // MARK: - Actions

    private func enablePush() async {
        isAskingPermission = true
        defer { isAskingPermission = false }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthStatus()
        guard granted || authStatus == .provisional else { return }
        await MainActor.run { appState.enablePushServer() }
        await store.load()
    }

    private func disablePush() async {
        await appState.disablePushServer()
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
        let orgText: String
        if rule.orgs.isEmpty {
            orgText = "全部處室"
        } else {
            orgText = "處室：" + rule.orgs.map { taxonomy.orgLabel(for: $0) }.joined(separator: "、")
        }
        let tagText: String
        if rule.tags.isEmpty {
            tagText = "全部類別"
        } else {
            tagText = "類別：" + rule.tags.map { taxonomy.tagLabel(for: $0) }.joined(separator: "、")
        }
        let joiner: String
        switch rule.mode {
        case .and: joiner = " 且 "
        case .or: joiner = " 或 "
        }
        return orgText + joiner + tagText
    }
}

import Defaults
import SwiftUI
import UserNotifications

struct BulletinNotificationSettingsView: View {
    let taxonomy: BulletinTaxonomyStore

    @Environment(AppEnvironment.self) private var app
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
            BulletinPushSection(
                pushEnabled: pushEnabled,
                authStatus: authStatus,
                isAskingPermission: isAskingPermission,
                isDisablingPush: isDisablingPush,
                pushUpdateFailed: pushUpdateFailed,
                onEnable: { Task { await enablePush() } },
                onDisable: { Task { await disablePush() } }
            )

            if pushEnabled {
                BulletinRulesSections(
                    store: store,
                    taxonomy: taxonomy,
                    editingClientId: $editingClientId,
                    draftRule: $draftRule
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "bulletin_notifications_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.configure(authTokenManager: app.authTokenManager, for: await app.authService.session.startingSignIn)
            await taxonomy.loadIfNeeded()
            await refreshAuthStatus()
            if pushEnabled, !didInitialLoad {
                didInitialLoad = true
                await store.load()
            }
        }
        .onChange(of: app.authService.session.currentSignIn) { _, signIn in
            (editingClientId, draftRule) = (nil, nil)
            store.configure(authTokenManager: app.authTokenManager, for: signIn)
            if pushEnabled { Task { await store.load() } }
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

    private func enablePush() async {
        isAskingPermission = true
        defer { isAskingPermission = false }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthStatus()
        guard granted || authStatus == .provisional else { return }
        do {
            try await app.pushSchedule.updateBulletinPushEnabled(true)
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
            try await app.pushSchedule.updateBulletinPushEnabled(false)
            pushUpdateFailed = false
        } catch {
            pushUpdateFailed = true
        }
    }

    private func refreshAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authStatus = settings.authorizationStatus
    }

    /// Whether the off-state section must explain the permission problem and offer iOS Settings,
    /// instead of leaving "Turn on bulletin push" as the only control. `.denied` is the one status
    /// the enable button cannot move: iOS never re-prompts after a refusal, so
    /// `requestAuthorization` returns `false` silently and `enablePush()` stops at its guard. The
    /// on-state branch's status row and Settings button are unreachable from here, so this section
    /// carries both.
    static func requiresSystemSettingsRoute(for status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .denied: return true
        case .authorized, .provisional, .ephemeral, .notDetermined: return false
        @unknown default: return true
        }
    }
}

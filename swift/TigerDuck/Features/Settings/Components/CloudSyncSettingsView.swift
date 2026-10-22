import Defaults
import SwiftUI

struct CloudSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.cloudSyncEnabled) private var syncEnabled
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames
    @Default(.syncAssignments) private var syncAssignments
    @Default(.serverPushUserOptOut) private var serverPushOptOut
    @State private var serverPushOptOutFailed: Bool = false
    @State private var serverPushOptOutTask: Task<Void, Never>?
    @State private var statusSnapshot: PushDiagnostic?
    @State private var asksToSignInAgain = false
    @State private var statusRefreshTimer: Timer?

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "sync_essential_toggle"), isOn: .constant(true))
                    .disabled(true)
            } footer: {
                Text(String(localized: "sync_essential_footer"))
            }

            Section {
                Toggle(String(localized: "sync_courses_toggle"), isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { old, newValue in
                        if newValue && !old {
                            if syncCourses { appState.markCategoryReenabled("courses") }
                            if syncCourseColors { appState.markCategoryReenabled("course_colors") }
                            if syncCourseNames { appState.markCategoryReenabled("course_names") }
                            if syncAssignments { appState.markCategoryReenabled("assignments") }
                            appState.checkPendingConflicts()
                        }
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "sync_courses_footer"))
                    Text(String(localized: "sync_courses_footer_platform_note"))
                }
            }

            Section {
                NavigationLink(String(localized: "sync_content_nav_label")) {
                    SyncContentSettingsView()
                }
            }

            Section {
                Toggle(String(localized: "settings_server_push_label"), isOn: serverPushBinding)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "settings_server_push_footer"))
                    if serverPushOptOutFailed {
                        Text(String(localized: "settings_server_push_update_failed"))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section(String(localized: "sync_status_nav_label")) {
                if let s = statusSnapshot {
                    syncStatusRow(
                        label: String(localized: "sync_status_device_registered"),
                        ok: s.registration.lastRegisteredAt != nil,
                        okText: String(localized: "push_server_status_done"),
                        badText: String(localized: "push_server_pending_incomplete")
                    )
                    if asksToSignInAgain {
                        signInAgainRow
                    } else if let err = s.registration.lastError {
                        LabeledContent(String(localized: "push_server_latest_error")) {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                    LabeledContent(String(localized: "cloud_sync_device_id")) {
                        Text(s.uuid)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            TigerSyncLinksSection(browserPreference: appState.browserPreference)
        }
        .navigationTitle(String(localized: "cloud_sync_title"))
        .task { await refreshStatusSnapshot() }
        .onAppear {
            appState.checkPendingConflicts()
            startStatusRefreshTimer()
        }
        .onDisappear {
            appState.checkPendingConflicts()
            stopStatusRefreshTimer()
        }
        .reenableConflictAlert()
    }

    private var serverPushBinding: Binding<Bool> {
        Binding(
            get: { !serverPushOptOut },
            set: { isOn in
                serverPushOptOutTask?.cancel()
                serverPushOptOutTask = Task {
                    do {
                        try await appState.updateServerPushOptOut(!isOn)
                        guard !Task.isCancelled else { return }
                        serverPushOptOutFailed = false
                    } catch {
                        guard !Task.isCancelled else { return }
                        serverPushOptOutFailed = true
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func syncStatusRow(label: String, ok: Bool, okText: String, badText: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(ok ? okText : badText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    private var signInAgainRow: some View {
        HStack {
            Text(String(localized: "common_auto_sign_in_failed"))
            Spacer()
            Button(String(localized: "action_sign_in_again")) {
                appState.presentNTUSTLogin()
            }
            .font(.callout.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func refreshStatusSnapshot() async {
        let snapshot = await appState.pushCoordinator.currentSnapshot()
        asksToSignInAgain = await appState.authService.asksToSignInAgain(
            syncEnabled: syncEnabled, after: snapshot.registration
        )
        statusSnapshot = snapshot
    }

    private func startStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await refreshStatusSnapshot() }
        }
    }

    private func stopStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
    }
}

struct TigerSyncLinksSection: View {
    let browserPreference: BrowserPreference

    @State private var inAppPage: InAppPage?

    var body: some View {
        Section {
            link(to: AppURLs.learnMoreTigerSync) {
                Label(String(localized: "settings_learn_more_backend"), systemImage: "server.rack")
            }
            link(to: AppURLs.privacyPolicy) {
                Label(String(localized: "onboarding_privacy_policy_label"), systemImage: "hand.raised.fill")
            }
            link(to: AppURLs.deleteAccount) {
                Label(String(localized: "onboarding_privacy_delete_account_label"), systemImage: "trash")
            }
        }
        .sheet(item: $inAppPage) { page in
            InAppBrowserView(url: page.url)
                .ignoresSafeArea()
                .keptOverReminders(page.url == AppURLs.deleteAccount)
        }
    }

    @ViewBuilder
    private func link<Content: View>(to url: URL, @ViewBuilder label: () -> Content) -> some View {
        if browserPreference == .inApp {
            Button { inAppPage = InAppPage(url: url) } label: { label() }
                .accessibilityRemoveTraits(.isButton)
                .accessibilityAddTraits(.isLink)
        } else {
            Link(destination: url, label: label)
        }
    }

    private struct InAppPage: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

struct ReenableConflictAlert: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "sync_conflict_title"),
            isPresented: AppState.reenableAlertIsPresented(Bindable(appState).reenableConflict)
        ) {
            Button(String(localized: "sync_conflict_use_server")) {
                appState.resolveReenableConflict(keepLocal: false)
            }
            Button(String(localized: "sync_conflict_use_local")) {
                appState.resolveReenableConflict(keepLocal: true)
            }
        } message: {
            Text(String(localized: "sync_conflict_reenable_message"))
            + Text("\n")
            + Text(appState.reenableConflict?.description ?? "")
        }
    }
}

extension View {
    func reenableConflictAlert() -> some View {
        modifier(ReenableConflictAlert())
    }
}

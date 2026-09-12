import Defaults
import SwiftUI

/// TigerSync settings (spec §6): essential-info notice, the course-sync
/// toggle with its "Synced content" drill-down, the server-push opt-out,
/// and an inline status section. See `SyncContentSettingsView` for the
/// six-toggle drill-down this screen links to.
struct CloudSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.cloudSyncEnabled) private var syncEnabled
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames
    @Default(.syncAssignments) private var syncAssignments
    @Default(.serverPushUserOptOut) private var serverPushOptOut
    /// Tracks whether the last server-push opt-out PATCH failed. Set inside
    /// `serverPushBinding`'s setter; the footer reads it to show the
    /// failure notice. The Toggle itself binds to `serverPushBinding`, not
    /// to this — the visual state reverts because that binding's getter
    /// re-reads the stored Default, which a failed PATCH never changed.
    @State private var serverPushOptOutFailed: Bool = false
    /// In-flight server-push opt-out PATCH, held so a rapid second tap can
    /// cancel the prior request before starting a new one.
    @State private var serverPushOptOutTask: Task<Void, Never>?
    /// Backs the inline TigerSync-status section below (spec §6, owner's
    /// ruling 2026-09-12, item 3). Owned here rather than by a pushed
    /// destination now that the section lives directly in this screen.
    @State private var statusSnapshot: PushDiagnostic?
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
                // Writes the preference itself; `AppState` acts on that the
                // way it acts on every change to it, whichever writer made it.
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
                        // Surfaces the rollback so the user knows the tap
                        // didn't take. The Toggle has already snapped back
                        // to the server-agreeing value because the actor
                        // only writes Defaults on success.
                        Text(String(localized: "settings_server_push_update_failed"))
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Unconditional per spec §6's tree: registration status and the
            // latest error are exactly what a user needs to see while
            // investigating why sync isn't working, which is
            // disproportionately likely to be a moment course sync is off.
            // Owner's ruling, 2026-09-12 (spec §6, item 3): reads inline as
            // a section titled with `sync_status_nav_label` itself rather
            // than a destination reached through it.
            Section(String(localized: "sync_status_nav_label")) {
                if let s = statusSnapshot {
                    syncStatusRow(
                        label: String(localized: "sync_status_device_registered"),
                        ok: s.registration.lastRegisteredAt != nil,
                        okText: String(localized: "push_server_status_done"),
                        badText: String(localized: "push_server_pending_incomplete")
                    )
                    if let err = s.registration.lastError {
                        LabeledContent(String(localized: "push_server_latest_error")) {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                Link(destination: AppURLs.learnMoreBackend) {
                    Label(String(localized: "settings_learn_more_backend"), systemImage: "server.rack")
                }
                Link(destination: AppURLs.privacyPolicy) {
                    Label(String(localized: "onboarding_privacy_policy_label"), systemImage: "hand.raised.fill")
                }
                Link(destination: AppURLs.deleteAccount) {
                    Label(String(localized: "onboarding_privacy_delete_account_label"), systemImage: "trash")
                }
            }
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

    /// User-facing opt-out for operator-issued "server" pushes. Bound as
    /// `isOn` (ON = user wants them); inverted into `serverPushUserOptOut`
    /// for storage. The setter awaits the actor, which PATCHes first and
    /// only writes the local Default on success — a throw trips
    /// `serverPushOptOutFailed` so the footer surfaces the failure and the
    /// Toggle stays at the prior, server-agreeing value.
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

    /// Registered means the server accepted this device, which is what
    /// `lastRegisteredAt` records — the Mac account tab reads the same. A
    /// push-to-start token only exists while Live Activities are on, so its
    /// length said nothing about whether reminders can reach here.
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

    private func refreshStatusSnapshot() async {
        statusSnapshot = await appState.pushCoordinator.currentSnapshot()
    }

    /// Keeps the inline status section current while this screen is the one
    /// on screen — the behaviour `SyncStatusPage` used to own as its own
    /// destination. Started from `onAppear` and invalidated from
    /// `onDisappear` so leaving this screen never leaves it running.
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

/// Re-enable conflict prompt (`AppState.reenableConflict`), shared by every
/// screen where a sync category can be switched back on: this screen's own
/// "Sync course information" toggle, and `SyncContentSettingsView`'s
/// per-category toggles. Not used by the Mac equivalent, which keeps its
/// own copy in `MacAccountSettingsView`.
struct ReenableConflictAlert: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content.alert(
            String(localized: "sync_conflict_title"),
            isPresented: Binding(
                get: { appState.reenableConflict != nil },
                set: { if !$0 { appState.resolveReenableConflict(keepLocal: true) } }
            )
        ) {
            Button(String(localized: "sync_conflict_use_server")) {
                appState.resolveReenableConflict(keepLocal: false)
            }
            Button(String(localized: "sync_conflict_use_local"), role: .cancel) {
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

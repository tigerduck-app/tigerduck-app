#if os(macOS)
import SwiftUI
import Defaults

struct MacTigerSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames
    @Default(.syncAssignments) private var syncAssignments
    @State private var snapshot: PushDiagnostic?
    @State private var asksToSignInAgain = false
    @State private var showSignIn = false
    @State private var refreshTimer: Timer?

    private static let childIndent: CGFloat = 16

    var body: some View {
        @Bindable var state = appState
        Form {
            Section {
                Toggle(String(localized: "sync_essential_toggle"), isOn: .constant(true))
                    .disabled(true)
            } footer: {
                Text(String(localized: "sync_essential_footer"))
            }

            Section {
                Toggle(String(localized: "sync_courses_toggle"), isOn: $state.cloudSyncEnabled)
                    .onChange(of: state.cloudSyncEnabled) { old, newValue in
                        if newValue && !old {
                            if syncCourses { appState.markCategoryReenabled("courses") }
                            if syncCourseColors { appState.markCategoryReenabled("course_colors") }
                            if syncCourseNames { appState.markCategoryReenabled("course_names") }
                            if syncAssignments { appState.markCategoryReenabled("assignments") }
                            appState.checkPendingConflicts()
                        }
                    }
            } footer: {
                Text(String(localized: "sync_courses_footer"))
            }

            if state.cloudSyncEnabled {
                Section {
                    Toggle(String(localized: "sync_content_nav_label"), isOn: syncedContent)

                    if syncedContentOn {
                        Text(String(localized: "cloud_sync_class_table"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Toggle(String(localized: "sync_content_class_table_all"), isOn: Binding(
                            get: { syncCourses },
                            set: { setCourses($0); commit() }
                        ))
                        .padding(.leading, Self.childIndent)
                        Toggle(String(localized: "cloud_sync_course_colours"), isOn: Binding(
                            get: { syncCourseColors },
                            set: { setCourseColors($0); commit() }
                        ))
                        .padding(.leading, Self.childIndent)
                        .disabled(!syncCourses)
                        Toggle(String(localized: "cloud_sync_custom_course_names"), isOn: Binding(
                            get: { syncCourseNames },
                            set: { setCourseNames($0); commit() }
                        ))
                        .padding(.leading, Self.childIndent)
                    }
                }
            }

            Section(String(localized: "sync_status_nav_label")) {
                if let s = snapshot {
                    syncStatusRow(
                        label: String(localized: "push_server_status_device_registration"),
                        ok: s.registration.lastRegisteredAt != nil,
                        okText: String(localized: "push_server_status_done"),
                        badText: String(localized: "push_server_pending_incomplete")
                    )
                    if asksToSignInAgain {
                        LabeledContent(String(localized: "common_auto_sign_in_failed")) {
                            Button(String(localized: "action_sign_in_again")) { showSignIn = true }
                        }
                    } else if let error = s.registration.lastError {
                        LabeledContent(String(localized: "push_server_latest_error")) {
                            Text(error).foregroundStyle(.red).font(.caption)
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

            Section {
                Link(destination: AppURLs.learnMoreTigerSync) {
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
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await refreshSnapshot() }
        .onAppear {
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in await refreshSnapshot() }
            }
            appState.checkPendingConflicts()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            appState.checkPendingConflicts()
        }
        .alert(
            String(localized: "sync_conflict_title"),
            isPresented: AppState.reenableAlertIsPresented($state.reenableConflict)
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
        .sheet(isPresented: $showSignIn) {
            MacLoginView(showsSkipButton: false, onSignedIn: { showSignIn = false })
                .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 560)
        }
    }

    private func refreshSnapshot() async {
        let current = await appState.pushCoordinator.currentSnapshot()
        asksToSignInAgain = await appState.authService.asksToSignInAgain(
            syncEnabled: appState.cloudSyncEnabled, after: current.registration
        )
        snapshot = current
    }

    private var syncedContentOn: Bool { syncCourses || syncCourseColors || syncCourseNames }

    private var syncedContent: Binding<Bool> {
        Binding(
            get: { syncedContentOn },
            set: { on in
                setCourses(on)
                setCourseColors(on)
                setCourseNames(on)
                commit()
            }
        )
    }

    private func setCourses(_ on: Bool) {
        if on && !syncCourses { appState.markCategoryReenabled("courses") }
        syncCourses = on
        setCourseColors(AppState.courseColorsAfterCoursesChange(coursesNowOn: on))
    }

    private func setCourseColors(_ on: Bool) {
        if on && !syncCourseColors { appState.markCategoryReenabled("course_colors") }
        syncCourseColors = on
    }

    private func setCourseNames(_ on: Bool) {
        if on && !syncCourseNames { appState.markCategoryReenabled("course_names") }
        syncCourseNames = on
    }

    private func commit() {
        appState.pushSyncPreferences()
        appState.checkPendingConflicts()
    }

    @ViewBuilder
    private func syncStatusRow(label: String, ok: Bool, okText: String, badText: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(ok ? okText : badText)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#endif

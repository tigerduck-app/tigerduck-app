#if os(macOS)
import SwiftUI
import Defaults

struct MacTigerSyncSettingsView: View {
    @Environment(AppEnvironment.self) private var app
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
        @Bindable var state = app
        @Bindable var conflicts = app.conflicts
        Form {
            Section {
                Toggle(String(localized: "sync_essential_toggle"), isOn: .constant(true))
                    .disabled(true)
            } footer: {
                Text(String(localized: "sync_essential_footer"))
            }

            Section {
                Toggle(String(localized: "sync_courses_toggle"), isOn: app.cloudSyncSwitch)
                    .onChange(of: state.cloudSyncEnabled) { old, newValue in
                        if newValue && !old {
                            if syncCourses { app.conflicts.markCategoryReenabled(.courses) }
                            if syncCourseColors { app.conflicts.markCategoryReenabled(.courseColors) }
                            if syncCourseNames { app.conflicts.markCategoryReenabled(.courseNames) }
                            if syncAssignments { app.conflicts.markCategoryReenabled(.assignments) }
                            app.conflicts.checkPendingConflicts()
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
            app.conflicts.checkPendingConflicts()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            app.conflicts.checkPendingConflicts()
        }
        .alert(
            String(localized: "sync_conflict_title"),
            isPresented: SyncConflicts.reenableAlertIsPresented($conflicts.reenableConflict)
        ) {
            Button(String(localized: "sync_conflict_use_server")) {
                app.conflicts.resolveReenableConflict(keepLocal: false)
            }
            Button(String(localized: "sync_conflict_use_local")) {
                app.conflicts.resolveReenableConflict(keepLocal: true)
            }
        } message: {
            Text(String(localized: "sync_conflict_reenable_message"))
            + Text("\n")
            + Text(app.conflicts.reenableConflict?.description ?? "")
        }
        .sheet(isPresented: $showSignIn) {
            MacLoginView(showsSkipButton: false, onSignedIn: { showSignIn = false })
                .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 560)
        }
    }

    private func refreshSnapshot() async {
        let current = await app.pushCoordinator.currentSnapshot()
        asksToSignInAgain = await app.authService.asksToSignInAgain(
            syncEnabled: app.cloudSyncEnabled, after: current.registration
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
        if on && !syncCourses { app.conflicts.markCategoryReenabled(.courses) }
        syncCourses = on
        setCourseColors(EditSender.courseColorsAfterCoursesChange(coursesNowOn: on))
    }

    private func setCourseColors(_ on: Bool) {
        if on && !syncCourseColors { app.conflicts.markCategoryReenabled(.courseColors) }
        syncCourseColors = on
    }

    private func setCourseNames(_ on: Bool) {
        if on && !syncCourseNames { app.conflicts.markCategoryReenabled(.courseNames) }
        syncCourseNames = on
    }

    private func commit() {
        app.pushSchedule.pushSyncPreferences()
        app.conflicts.checkPendingConflicts()
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

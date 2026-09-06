#if os(macOS)
import SwiftUI
import Defaults

/// Account tab — sign-in state, push registration diagnostics, and the
/// per-category cloud-sync switches. One of the six tabs assembled by
/// `MacSettingsScene`.
struct MacAccountSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Default(.pushLastRegistrationAt) private var lastRegistrationAt
    @Default(.pushLastSyncAt) private var lastSyncAt
    @Default(.syncCourses) private var macSyncCourses
    @Default(.syncCourseColors) private var macSyncCourseColors
    @Default(.syncCourseNames) private var macSyncCourseNames
    @Default(.syncAssignments) private var macSyncAssignments
    @State private var showSignIn = false
    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?

    var body: some View {
        @Bindable var state = appState
        Form {
            Section(String(localized: "desktop_settings_section_ntust")) {
                if appState.authService.hasStoredCredentials {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text(String(localized: "desktop_settings_signed_in_ntust"))
                    }
                    Button(role: .destructive) {
                        appState.logoutNTUST()
                    } label: {
                        Label(String(localized: "action_sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Text(String(localized: "common_not_signed_in"))
                        .foregroundStyle(.secondary)
                    Button {
                        showSignIn = true
                    } label: {
                        Label(String(localized: "action_sign_in"), systemImage: "person.badge.key.fill")
                    }
                }
            }

            Section(String(localized: "cloud_sync_title")) {
                Toggle(String(localized: "cloud_sync_title"), isOn: $state.cloudSyncEnabled)
                    .onChange(of: state.cloudSyncEnabled) { old, newValue in
                        if newValue && !old {
                            if macSyncCourses { appState.markCategoryReenabled("courses") }
                            if macSyncCourseColors { appState.markCategoryReenabled("course_colors") }
                            if macSyncCourseNames { appState.markCategoryReenabled("course_names") }
                            if macSyncAssignments { appState.markCategoryReenabled("assignments") }
                            appState.checkPendingConflicts()
                        }
                    }

                if state.cloudSyncEnabled {
                    Toggle(String(localized: "cloud_sync_assignments"), isOn: $macSyncAssignments)
                        .onChange(of: macSyncAssignments) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("assignments")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }

                    Toggle(String(localized: "cloud_sync_class_table"), isOn: Binding(
                        get: { macSyncCourses || macSyncCourseColors || macSyncCourseNames },
                        set: { newValue in
                            if newValue && !(macSyncCourses || macSyncCourseColors || macSyncCourseNames) {
                                appState.markCategoryReenabled("courses")
                                appState.markCategoryReenabled("course_colors")
                                appState.markCategoryReenabled("course_names")
                                appState.checkPendingConflicts()
                            }
                            macSyncCourses = newValue
                            macSyncCourseColors = newValue
                            macSyncCourseNames = newValue
                            appState.pushSyncPreferences()
                        }
                    ))

                    if macSyncCourses || macSyncCourseColors || macSyncCourseNames {
                        Toggle(String(localized: "cloud_sync_courses"), isOn: Binding(
                            get: { macSyncCourses },
                            set: { newValue in
                                if newValue && !macSyncCourses {
                                    appState.markCategoryReenabled("courses")
                                    appState.checkPendingConflicts()
                                }
                                macSyncCourses = newValue
                                if !newValue {
                                    macSyncCourseColors = false
                                }
                                appState.pushSyncPreferences()
                            }
                        ))
                            .padding(.leading, 20)
                        Toggle(String(localized: "cloud_sync_course_colours"), isOn: $macSyncCourseColors)
                            .padding(.leading, 20)
                            .disabled(!macSyncCourses)
                            .onChange(of: macSyncCourseColors) { old, new in
                                if new && !old {
                                    appState.markCategoryReenabled("course_colors")
                                    appState.checkPendingConflicts()
                                }
                                appState.pushSyncPreferences()
                            }
                        Toggle(String(localized: "cloud_sync_custom_course_names"), isOn: $macSyncCourseNames)
                            .padding(.leading, 20)
                            .onChange(of: macSyncCourseNames) { old, new in
                                if new && !old {
                                    appState.markCategoryReenabled("course_names")
                                    appState.checkPendingConflicts()
                                }
                                appState.pushSyncPreferences()
                            }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "settings_sync_brief_description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link(destination: AppURLs.learnMoreBackend) {
                        HStack(spacing: 4) {
                            Text(String(localized: "settings_learn_more_backend"))
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption2)
                        }
                        .font(.callout)
                    }
                }

                Button {
                    appState.backgroundSync()
                } label: {
                    Label(String(localized: "cloud_sync_sync_now"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!state.cloudSyncEnabled || appState.sessionManager.loadingState == .loading)
            }

            if state.cloudSyncEnabled, let s = snapshot {
                Section(String(localized: "push_server_status_section")) {
                    syncStatusRow(
                        label: String(localized: "push_server_status_device_registration"),
                        ok: s.registration.lastRegisteredAt != nil,
                        okText: String(localized: "push_server_status_done"),
                        badText: String(localized: "push_server_pending_incomplete")
                    )
                    LabeledContent(String(localized: "push_server_last_registration")) {
                        if let at = lastRegistrationAt {
                            Text(at, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text(String(localized: "push_server_pending_incomplete")).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(String(localized: "push_server_last_sync")) {
                        if let at = lastSyncAt {
                            Text(at, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text(String(localized: "push_server_pending_incomplete")).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Device ID") {
                        Text(s.uuid)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if let error = s.registration.lastError {
                        LabeledContent(String(localized: "push_server_latest_error")) {
                            Text(error).foregroundStyle(.red).font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { snapshot = await appState.pushCoordinator.currentSnapshot() }
        .onAppear {
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { @MainActor in snapshot = await appState.pushCoordinator.currentSnapshot() }
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
        .sheet(isPresented: $showSignIn) {
            MacLoginView(showsSkipButton: false)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 520, idealHeight: 560)
                .onChange(of: appState.authService.hasStoredCredentials) { _, signedIn in
                    if signedIn { showSignIn = false }
                }
        }
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

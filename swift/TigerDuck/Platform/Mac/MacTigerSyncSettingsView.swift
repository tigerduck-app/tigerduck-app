#if os(macOS)
import SwiftUI
import Defaults

/// TigerSync tab — the Mac's counterpart of the iPhone/iPad TigerSync
/// screen (spec §6), minus what a Mac cannot use: no server-push opt-out
/// and none of the notification rows, because macOS takes no
/// notifications. One of the tabs assembled by `MacSettingsScene`.
///
/// Synced content is a parent switch with no stored value of its own, as
/// on iPhone, iPad and Android: it reads on while any class-table row is
/// on, flipping it sets all three, and the rows are hidden while it is
/// off. The whole group is hidden while Sync course information is off,
/// so a category the user cannot see can never pick up a re-enable mark.
struct MacTigerSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames
    @Default(.syncAssignments) private var syncAssignments
    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?

    /// Sets a class-table row under its category heading.
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
                // No platform note here — `sync_courses_footer_platform_note`
                // is about the iOS-only Live Activity / reminder fallout of
                // turning this off, and macOS has neither.
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
                    if let error = s.registration.lastError {
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
    }

    private var syncedContentOn: Bool { syncCourses || syncCourseColors || syncCourseNames }

    /// The parent switch. The rows it reveals are not on screen yet when it
    /// turns on, and are gone once it turns off, so it does their work
    /// itself rather than leaning on anything attached to them.
    private var syncedContent: Binding<Bool> {
        Binding(
            get: { syncedContentOn },
            set: { on in
                // Courses first: colours only turn on over synced courses.
                setCourses(on)
                setCourseColors(on)
                setCourseNames(on)
                commit()
            }
        )
    }

    // Each setter writes one flag the way a tap on its row would, marking a
    // category that comes back on for the re-enable conflict check; the
    // caller then pushes the flags and runs that check once.

    private func setCourses(_ on: Bool) {
        if on && !syncCourses { appState.markCategoryReenabled("courses") }
        syncCourses = on
        // Spec §6's course-sync → course-colours dependency, through the
        // decision function every platform's class-table rows share.
        syncCourseColors = AppState.courseColorsAfterCoursesChange(
            coursesNowOn: on,
            coloursCurrentlyOn: syncCourseColors
        )
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

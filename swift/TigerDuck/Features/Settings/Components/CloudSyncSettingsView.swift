import Defaults
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct CloudSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.cloudSyncEnabled) private var syncEnabled
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames
    @Default(.syncAssignments) private var syncAssignments
    @Default(.pushLastRegistrationAt) private var lastRegistrationAt
    @Default(.pushLastSyncAt) private var lastSyncAt
    @State private var snapshot: PushDiagnostic?

    #if os(iOS)
    @State private var copyStatus: CopyResult?
    @State private var copyResetTask: Task<Void, Never>?
    private enum CopyResult { case copied, blocked }
    #endif

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "cloud_sync_title"), isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, newValue in
                        appState.cloudSyncEnabled = newValue
                    }
            } footer: {
                #if os(iOS)
                Text(String(localized: "settings_sync_brief_description_ios"))
                #else
                Text(String(localized: "settings_sync_brief_description"))
                #endif
            }

            if syncEnabled {
                Section("Sync options") {
                    Toggle(String(localized: "cloud_sync_assignments"), isOn: $syncAssignments)
                        .onChange(of: syncAssignments) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("assignments")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }

                    NavigationLink {
                        classTableSyncOptions
                    } label: {
                        HStack {
                            Text(String(localized: "cloud_sync_class_table"))
                            Spacer()
                            let count = [syncCourses, syncCourseColors, syncCourseNames].filter { $0 }.count
                            Text("\(count)/3")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            } else {
                Section {
                    Label(
                        String(localized: "settings_sync_disabled_note"),
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            if syncEnabled {
                if let err = snapshot?.registration.lastError {
                    Section(String(localized: "push_server_latest_error")) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                if let s = snapshot {
                    Section(String(localized: "push_server_status_section")) {
                        statusRow(label: String(localized: "push_server_status_device_registration"),
                                  ok: s.registration.ptsTokenLength > 0,
                                  okText: String(localized: "push_server_status_done"),
                                  badText: String(localized: "push_server_status_waiting_token"))
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
                        Button {
                            appState.requestPushScheduleSync()
                        } label: {
                            Label(String(localized: "cloud_sync_sync_now"), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }

                    #if os(iOS)
                    Section {
                        idRow(label: "Device ID", value: s.uuid)
                    } header: {
                        Text(String(localized: "push_server_ids_section"))
                    } footer: {
                        if let footer = copyFooter {
                            Text(footer.text).foregroundStyle(footer.color)
                        }
                    }
                    #endif
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
        .task { await refreshSnapshot() }
        .onAppear {
            startRefreshTimer()
            appState.checkPendingConflicts()
        }
        .onDisappear {
            stopRefreshTimer()
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

    @State private var refreshTimer: Timer?

    private func refreshSnapshot() async {
        snapshot = await appState.pushCoordinator.currentSnapshot()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { await refreshSnapshot() }
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @ViewBuilder
    private func statusRow(label: String, ok: Bool, okText: String, badText: String) -> some View {
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

    #if os(iOS)
    @ViewBuilder
    private func idRow(label: String, value: String) -> some View {
        Button {
            copyToPasteboard(value: value)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: copyStatus == .copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copyStatus == .copied ? .green : .secondary)
                        .font(.caption)
                }
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func copyToPasteboard(value: String) {
        let pb = UIPasteboard.general
        pb.string = value
        copyStatus = (pb.string == value) ? .copied : .blocked
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            copyStatus = nil
            copyResetTask = nil
        }
    }

    private var copyFooter: (text: String, color: Color)? {
        if copyStatus == .blocked {
            return ("Copy blocked — pasteboard access is restricted on this device.", .orange)
        }
        if copyStatus == .copied {
            return ("Copied.", .green)
        }
        return nil
    }
    #endif

    private var classTableMasterBinding: Binding<Bool> {
        Binding(
            get: { syncCourses || syncCourseColors || syncCourseNames },
            set: { newValue in
                if newValue && !(syncCourses || syncCourseColors || syncCourseNames) {
                    appState.markCategoryReenabled("courses")
                    appState.markCategoryReenabled("course_colors")
                    appState.markCategoryReenabled("course_names")
                    appState.checkPendingConflicts()
                }
                syncCourses = newValue
                syncCourseColors = newValue
                syncCourseNames = newValue
                appState.pushSyncPreferences()
            }
        )
    }

    private var classTableSyncOptions: some View {
        Form {
            Section {
                Toggle(String(localized: "cloud_sync_class_table"), isOn: classTableMasterBinding)
            } footer: {
                Text(String(localized: "cloud_sync_class_table_footer"))
            }

            if syncCourses || syncCourseColors || syncCourseNames {
                Section {
                    Toggle(String(localized: "cloud_sync_courses"), isOn: Binding(
                        get: { syncCourses },
                        set: { newValue in
                            if newValue && !syncCourses {
                                appState.markCategoryReenabled("courses")
                                appState.checkPendingConflicts()
                            }
                            syncCourses = newValue
                            if !newValue {
                                syncCourseColors = false
                            }
                            appState.pushSyncPreferences()
                        }
                    ))
                    Toggle(String(localized: "cloud_sync_course_colours"), isOn: $syncCourseColors)
                        .disabled(!syncCourses)
                        .onChange(of: syncCourseColors) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("course_colors")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }
                    Toggle(String(localized: "cloud_sync_custom_course_names"), isOn: $syncCourseNames)
                        .onChange(of: syncCourseNames) { old, new in
                            if new && !old {
                                appState.markCategoryReenabled("course_names")
                                appState.checkPendingConflicts()
                            }
                            appState.pushSyncPreferences()
                        }
                }
            }
        }
        .navigationTitle(String(localized: "cloud_sync_class_table_sync"))
    }
}

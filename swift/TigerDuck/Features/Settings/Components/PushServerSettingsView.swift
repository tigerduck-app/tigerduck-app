import Defaults
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// Settings page for the push notification server.
///
/// The status section stays so users (and us in support) can see at a
/// glance whether the pipeline is healthy. The raw server URL and the
/// debug override field are intentionally not shown — users don't need
/// them, and exposing them makes the screen feel like a dev console.
struct PushServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.pushServerEnabled) private var pushServerEnabled
    @Default(.pushLastRegistrationAt) private var lastRegistrationAt
    @Default(.pushLastSyncAt) private var lastSyncAt
    @Default(.serverPushUserOptOut) private var serverPushOptOut

    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?
    @State private var disableTask: Task<Void, Never>?
    /// Tracks whether the server-push opt-out PATCH is in flight or
    /// rolled back. The Toggle binds against this so a failed PATCH
    /// can revert the visual state in lock-step with the stored Default.
    @State private var serverPushOptOutFailed: Bool = false
    /// In-flight server-push opt-out PATCH. Held so a rapid second tap
    /// can cancel the prior request before starting a new one — without
    /// this, two independent tasks race and the slower one can overwrite
    /// the latest user choice.
    @State private var serverPushOptOutTask: Task<Void, Never>?
    #if os(iOS)
    // Per-row copy state. `nil` = idle (no recent action). Last tap wins
    // the shared footer so the user gets immediate feedback without us
    // having to render two footer messages side by side.
    @State private var copyStatus: [IdKind: CopyResult] = [:]
    /// Reset Tasks keyed per row so rapid double-taps cancel the prior
    /// timer instead of letting it wake mid-feedback for the second tap.
    @State private var copyResetTasks: [IdKind: Task<Void, Never>] = [:]

    private enum IdKind: Hashable { case device }
    private enum CopyResult { case copied, blocked }
    #endif

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "push_server_enable_toggle"), isOn: toggleBinding)
            } footer: {
                Text(String(localized: "push_server_footer"))
            }

            Section {
                Toggle(String(localized: "settings_server_push_label"), isOn: serverPushBinding)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "settings_server_push_footer"))
                    if serverPushOptOutFailed {
                        // Surfaces the rollback so the user knows the
                        // tap didn't take. The Toggle has already
                        // snapped back to the server-agreeing value
                        // because the actor only writes Defaults on
                        // success.
                        Text("Server didn't accept the change — try again later.")
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Always surface the latest registration/sync error (matches
            // Android, which shows it unconditionally) — and make it
            // selectable so it can be copied for support. Shown even when the
            // status section below is hidden by the enable toggle.
            if let err = snapshot?.registration.lastError {
                Section(String(localized: "push_server_latest_error")) {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if pushServerEnabled, let s = snapshot {
                Section(String(localized: "push_server_status_section")) {
                    statusRow(label: String(localized: "push_server_status_live_activities"),
                              ok: s.liveActivitiesEnabled,
                              okText: String(localized: "push_server_status_enabled"),
                              badText: String(localized: "push_server_status_settings_hint"))
                    statusRow(label: String(localized: "permission_notifications_name"),
                              ok: s.notificationAuthStatus == .authorized || s.notificationAuthStatus == .provisional,
                              okText: notificationStatusText(s.notificationAuthStatus),
                              badText: notificationStatusText(s.notificationAuthStatus))
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
                    Button(String(localized: "push_server_sync_now_action")) { appState.requestPushScheduleSync() }
                }

                #if os(iOS)
                Section {
                    idRow(kind: .device, label: "Device ID", value: s.uuid)
                } header: {
                    Text(String(localized: "push_server_ids_section"))
                } footer: {
                    // Only render the footer when there's actual feedback
                    // to show — the idle hint was noise once the icon in
                    // the row already telegraphs tap-to-copy.
                    if let footer = copyFooter {
                        Text(footer.text).foregroundStyle(footer.color)
                    }
                }
                #endif
            }
        }
        .navigationTitle(String(localized: "push_server_settings_title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSnapshot() }
        .onAppear {
            refreshTimer?.invalidate()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                Task { await refreshSnapshot() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func idRow(kind: IdKind, label: String, value: String) -> some View {
        Button {
            copyToPasteboard(kind: kind, value: value)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: copyStatus[kind] == .copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copyStatus[kind] == .copied ? .green : .secondary)
                        .font(.caption)
                }
                // No lineLimit / truncation — IDs are short today (UUIDs)
                // but tokens we might surface here later can be 150+ chars,
                // and the user explicitly asked for the full value to be
                // visible. `fixedSize(vertical:)` keeps the row from being
                // clipped to a single line by the surrounding Form metrics.
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

    private func copyToPasteboard(kind: IdKind, value: String) {
        let pb = UIPasteboard.general
        pb.string = value
        // MDM-managed devices can block pasteboard writes silently
        // (`UIPasteboard.string =` is non-throwing), so confirm via
        // read-back rather than assuming success. Compare to the value
        // we just wrote (not just hasStrings) so we don't falsely
        // confirm when an unrelated string was already on the board.
        copyStatus[kind] = (pb.string == value) ? .copied : .blocked
        // Cancel any earlier reset so its 1.5s timer can't fire during
        // a freshly-confirmed copy on the same row.
        copyResetTasks[kind]?.cancel()
        copyResetTasks[kind] = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            copyStatus[kind] = nil
            copyResetTasks[kind] = nil
        }
    }

    private var copyFooter: (text: String, color: Color)? {
        if copyStatus.values.contains(.blocked) {
            return (
                "Copy blocked — pasteboard access is restricted on this device (likely an MDM profile).",
                .orange
            )
        }
        if copyStatus.values.contains(.copied) {
            return ("Copied.", .green)
        }
        return nil
    }
    #endif

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { pushServerEnabled },
            set: { newValue in
                if newValue {
                    appState.enablePushServer()
                } else {
                    disableTask?.cancel()
                    disableTask = Task { await appState.disablePushServer() }
                }
                Task { await refreshSnapshot() }
            }
        )
    }

    /// User-facing opt-out for operator-issued "server" pushes. Bound as
    /// `isOn` (i.e. ON = user wants to receive them); we invert into
    /// `serverPushUserOptOut` for storage.
    ///
    /// The setter awaits the actor, which PATCHes first and only writes
    /// the local Default on success. A throw rolls back any optimistic
    /// `@Default` write the system might surface and trips
    /// `serverPushOptOutFailed` so the footer surfaces the failure.
    private var serverPushBinding: Binding<Bool> {
        Binding(
            get: { !serverPushOptOut },
            set: { isOn in
                // Cancel any prior PATCH so only the latest tap can
                // finish writing the stored opt-out. Two independent
                // tasks would otherwise race: if the user flips off
                // then quickly back on, the slower first request could
                // finish last and overwrite the second one's value.
                serverPushOptOutTask?.cancel()
                serverPushOptOutTask = Task {
                    do {
                        try await appState.updateServerPushOptOut(!isOn)
                        // Superseded mid-flight — let the newer task own
                        // the UI state. (URLSession surfaces cancellation
                        // as `URLError(.cancelled)` rather than
                        // `CancellationError`, so we gate on
                        // `Task.isCancelled` rather than the error type.)
                        guard !Task.isCancelled else { return }
                        serverPushOptOutFailed = false
                    } catch {
                        guard !Task.isCancelled else { return }
                        // Server didn't accept the change — flag for the
                        // shared footer. The @Default never flipped (the
                        // actor only writes on success) so the Toggle
                        // reflects the prior, server-agreeing value.
                        serverPushOptOutFailed = true
                    }
                }
            }
        )
    }

    private func refreshSnapshot() async {
        snapshot = await appState.pushCoordinator.currentSnapshot()
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

    private func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return String(localized: "push_server_notification_status_undetermined")
        case .denied: return String(localized: "push_server_notification_status_denied_hint")
        case .authorized: return String(localized: "push_server_notification_status_authorized")
        case .provisional: return String(localized: "push_server_notification_status_provisional")
        case .ephemeral: return String(localized: "push_server_notification_status_ephemeral")
        @unknown default: return String(localized: "push_server_notification_status_unknown")
        }
    }
}

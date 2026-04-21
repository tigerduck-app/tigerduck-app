import Defaults
import SwiftUI
import UserNotifications

/// Settings page for the push notification server.
///
/// Shows the full diagnostic state: toggle, Live Activity permission,
/// notification permission, token lengths, last sync / last error, resolved
/// server URL. Makes the otherwise-invisible push pipeline debuggable.
struct PushServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.pushServerEnabled) private var pushServerEnabled
    @Default(.pushServerURLOverride) private var pushServerURLOverride
    @Default(.pushLastRegistrationAt) private var lastRegistrationAt
    @Default(.pushLastSyncAt) private var lastSyncAt

    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?
    @State private var disableTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("啟用伺服器推播", isOn: toggleBinding)
            } footer: {
                Text("由 TigerDuck 伺服器在設定時間主動觸發動態島，App 不需開啟也能收到通知。")
            }

            if pushServerEnabled, let s = snapshot {
                Section("狀態") {
                    statusRow(label: "Live Activities",
                              ok: s.liveActivitiesEnabled,
                              okText: "已啟用",
                              badText: "系統層關閉 → iOS 設定 → TigerDuck 開啟")
                    statusRow(label: "通知權限",
                              ok: s.notificationAuthStatus == .authorized || s.notificationAuthStatus == .provisional,
                              okText: notificationStatusText(s.notificationAuthStatus),
                              badText: notificationStatusText(s.notificationAuthStatus))
                    statusRow(label: "APNs device token",
                              ok: s.registration.deviceTokenLength > 0,
                              okText: "\(s.registration.deviceTokenLength) chars",
                              badText: "尚未取得（等 iOS APNs 回呼）")
                    statusRow(label: "Push-to-Start token",
                              ok: s.registration.ptsTokenLength > 0,
                              okText: "\(s.registration.ptsTokenLength) chars",
                              badText: "尚未取得（等 ActivityKit 指派）")
                    LabeledContent("註冊") {
                        if let at = lastRegistrationAt {
                            Text(at, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text("尚未完成").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("同步") {
                        if let at = lastSyncAt {
                            Text(at, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text("尚未完成").foregroundStyle(.secondary)
                        }
                    }
                    if let err = s.registration.lastError {
                        LabeledContent("最近錯誤") {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Button("立即同步一次") { appState.requestPushScheduleSync() }
                }

                Section("伺服器") {
                    LabeledContent("URL") {
                        Text(s.resolvedServerURL.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            #if DEBUG
            Section {
                TextField(
                    "https://api.tigerduck.app/v1",
                    text: serverOverrideBinding
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                Text("開發者：伺服器 URL 覆寫")
            } footer: {
                Text("留空使用正式環境。只影響除錯組建。修改後重啟 app 生效。")
            }
            #endif
        }
        .navigationTitle("伺服器推播")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshSnapshot() }
        .onAppear {
            // Refresh every 2s while visible so the user can watch PTS /
            // device tokens arrive without leaving the screen.
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

    private var serverOverrideBinding: Binding<String> {
        Binding(
            get: { pushServerURLOverride ?? "" },
            set: { new in
                let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
                pushServerURLOverride = trimmed.isEmpty ? nil : trimmed
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
        case .notDetermined: return "尚未詢問"
        case .denied: return "被拒（至 iOS 設定開啟）"
        case .authorized: return "已授權"
        case .provisional: return "靜默授權"
        case .ephemeral: return "暫時授權"
        @unknown default: return "未知"
        }
    }
}

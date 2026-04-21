import Defaults
import SwiftUI
import UserNotifications

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

    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?
    @State private var disableTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("啟用伺服器推播", isOn: toggleBinding)
            } footer: {
                Text("用於接收學校即時公告訊息、主動觸發動態島等提醒。")
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
                    statusRow(label: "裝置註冊",
                              ok: s.registration.ptsTokenLength > 0,
                              okText: "完成",
                              badText: "等 iOS 指派 token")
                    LabeledContent("上次註冊") {
                        if let at = lastRegistrationAt {
                            Text(at, style: .relative).foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text("尚未完成").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("上次同步") {
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
            }
        }
        .navigationTitle("伺服器推播")
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

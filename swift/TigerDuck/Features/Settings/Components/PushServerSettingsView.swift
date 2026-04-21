import Defaults
import SwiftUI

/// Settings page for the push notification server.
///
/// The toggle drives `AppState.enablePushServer()` / `disablePushServer()`.
/// When enabled, the coordinator:
/// 1. Registers for remote notifications (iOS prompts for permission if needed).
/// 2. Starts observing `Activity<>.pushToStartTokenUpdates`.
/// 3. POSTs an initial schedule sync.
///
/// The "伺服器" text field only appears in debug builds. Production talks to
/// `AppConstants.defaultPushServerURL` (https://api.tigerduck.app/v1).
struct PushServerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.pushServerEnabled) private var pushServerEnabled
    @Default(.pushServerURLOverride) private var pushServerURLOverride
    @Default(.pushLastRegistrationAt) private var lastRegistrationAt
    @Default(.pushLastSyncAt) private var lastSyncAt

    @State private var disableTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Toggle("啟用伺服器推播", isOn: toggleBinding)
            } footer: {
                Text("由 TigerDuck 伺服器在設定時間主動觸發動態島，App 不需開啟也能收到通知。")
            }

            if pushServerEnabled {
                Section("狀態") {
                    statusRow(label: "註冊", date: lastRegistrationAt)
                    statusRow(label: "同步", date: lastSyncAt)
                    Button {
                        appState.requestPushScheduleSync()
                    } label: {
                        Text("立即同步一次")
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
                Text("留空使用正式環境。只影響除錯組建。")
            }
            #endif
        }
        .navigationTitle("伺服器推播")
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private func statusRow(label: String, date: Date?) -> some View {
        LabeledContent(label) {
            if let date {
                Text(date, style: .relative)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("尚未完成")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

import SwiftUI

/// Settings page for reminder offsets and Live Activity toggles.
/// Lives behind a NavigationLink in SettingsView so the top-level list
/// stays short.
struct LiveActivitySettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Toggle("啟用動態靈動 (Live Activity)", isOn: $store.isLiveActivityEnabled)
            } footer: {
                Text("會在鎖定畫面與 Dynamic Island 顯示當前課程或緊急作業。\n\n情境切換目前需 App 在前景才會即時更新；若 App 在背景或裝置鎖定，要等下次回到前景才會跟上時段。")
            }

            Section("顯示情境") {
                Toggle("上課中", isOn: $store.showInClassScenario)
                Toggle("即將上課", isOn: $store.showClassPreparingScenario)
                Toggle("作業緊急", isOn: $store.showAssignmentScenario)
            }
            .disabled(!store.isLiveActivityEnabled)

            Section("顯示時機") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("作業進入 Live Activity")
                        Spacer()
                        Text(formatHours(store.assignmentLiveActivityLeadTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $store.assignmentLiveActivityLeadTime,
                        in: 3600 ... LiveActivityPreferencesStore.maximumAssignmentLeadTime,
                        step: 3600
                    )
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("下一節課提前視窗")
                        Spacer()
                        Text(formatMinutes(store.classPreparingLeadTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $store.classPreparingLeadTime,
                        in: 5 * 60 ... 60 * 60,
                        step: 5 * 60
                    )
                }
            }
            .disabled(!store.isLiveActivityEnabled)

            Section {
                ForEach(AssignmentReminderOffset.allCases) { offset in
                    Toggle(offset.label, isOn: bindingForOffset(offset))
                }
            } header: {
                Text("作業提醒時機")
            } footer: {
                Text("每個時機會在作業截止前透過本機通知提醒。")
            }

            Section {
                Button("重置為預設值", role: .destructive) {
                    store.resetToDefaults()
                }
            }
        }
        .navigationTitle("通知與動態靈動")
        .task {
            // Request notification permission only at this explicit entry
            // point. Refresh paths (theme tweaks, foreground transitions,
            // background syncs) intentionally never prompt.
            await appState.requestNotificationAuthorization()
        }
    }

    private func bindingForOffset(_ offset: AssignmentReminderOffset) -> Binding<Bool> {
        Binding(
            get: { store.assignmentReminderOffsets.contains(offset) },
            set: { newValue in
                if newValue {
                    store.assignmentReminderOffsets.insert(offset)
                } else {
                    store.assignmentReminderOffsets.remove(offset)
                }
            }
        )
    }

    private func formatHours(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3600)
        return "\(hours) 小時"
    }

    private func formatMinutes(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return "\(minutes) 分鐘"
    }
}

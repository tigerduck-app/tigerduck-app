import SwiftUI

/// Settings page for reminder offsets and Live Activity toggles.
/// Lives behind a NavigationLink in SettingsView so the top-level list
/// stays short.
struct LiveActivitySettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState
    @State private var showResetConfirmation = false
    @State private var resetFeedbackTrigger = 0

    var body: some View {
        Form {
            Section {
                Toggle("啟用即時動態 Live Activity", isOn: $store.isLiveActivityEnabled)
            } footer: {
                Text("會在鎖定畫面或動態島顯示當前課程和作業。\n\n需 App 在開啟才會即時更新")
            }

            Section("顯示情境") {
                Toggle("上課中", isOn: $store.showInClassScenario)
                Toggle("即將上課", isOn: $store.showClassPreparingScenario)
                Toggle("作業", isOn: $store.showAssignmentScenario)
            }
            .disabled(!store.isLiveActivityEnabled)

            Section("顯示時機") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("作業警告")
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
                        Text("即將上課")
                        Spacer()
                        Text(formatHoursAndMinutes(store.classPreparingLeadTime))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $store.classPreparingLeadTime,
                        in: LiveActivityPreferencesStore.minimumClassPreparingLeadTime
                            ... LiveActivityPreferencesStore.maximumClassPreparingLeadTime,
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
                Text("作業通知")
            } footer: {
                Text("作業截止前會發通知敲您")
            }

            Section {
                Button("重置為預設值", role: .destructive) {
                    showResetConfirmation = true
                }
                .confirmationDialog(
                    "重置所有即時動態設定？",
                    isPresented: $showResetConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("重置", role: .destructive) {
                        store.resetToDefaults()
                        resetFeedbackTrigger &+= 1
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("所有情境、提醒時機、顯示時機將還原為預設值。")
                }
                .sensoryFeedback(.success, trigger: resetFeedbackTrigger)
            }
        }
        .navigationTitle("即時動態 Live Activity（實驗性）")
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

    private func formatHoursAndMinutes(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes) 分鐘" }
        if minutes == 0 { return "\(hours) 小時" }
        return "\(hours) 小時 \(minutes) 分鐘"
    }
}

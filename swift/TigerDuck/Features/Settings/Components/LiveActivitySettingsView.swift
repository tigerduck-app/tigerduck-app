import SwiftUI

/// Settings page for reminder offsets and Live Activity toggles.
/// Lives behind a NavigationLink in SettingsView so the top-level list
/// stays short.
struct LiveActivitySettingsView: View {
    @Bindable var store: LiveActivityPreferencesStore
    @Environment(AppState.self) private var appState
    @State private var showResetConfirmation = false
    @State private var resetFeedbackTrigger = 0
    // Transient drag values: while the user is dragging a slider we keep the
    // value in local state so each step does not thrash the store (which would
    // post a NotificationCenter event, spawn a debounced refresh task, and
    // invalidate any @Observable consumer — all of which can interrupt the
    // in-flight gesture and animate the thumb after release). We commit once
    // on onEditingChanged(false).
    @State private var draftAssignmentLead: TimeInterval?
    @State private var draftClassPreparingLead: TimeInterval?

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
                // Both sliders drop the `step:` parameter — it enables SwiftUI's
                // built-in step-crossing haptic, which turns into rapid-fire
                // vibration when the user hovers at an extreme value (tiny
                // finger jitter crosses the final step boundary repeatedly).
                // We snap the value ourselves inside the binding setter so the
                // thumb still lands on discrete positions without the haptic.
                let assignmentLead = draftAssignmentLead ?? store.assignmentLiveActivityLeadTime
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("作業警告")
                        Spacer()
                        Text(formatHours(assignmentLead))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { assignmentLead },
                            set: { raw in
                                let snapped = Self.snap(raw, step: 3600)
                                if draftAssignmentLead != snapped {
                                    draftAssignmentLead = snapped
                                }
                            }
                        ),
                        in: 3600 ... LiveActivityPreferencesStore.maximumAssignmentLeadTime,
                        onEditingChanged: { editing in
                            if !editing, let value = draftAssignmentLead {
                                store.assignmentLiveActivityLeadTime = value
                                draftAssignmentLead = nil
                            }
                        }
                    )
                }
                let classLead = draftClassPreparingLead ?? store.classPreparingLeadTime
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("即將上課")
                        Spacer()
                        Text(formatMinutes(classLead))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { classLead },
                            set: { raw in
                                let snapped = Self.snap(raw, step: 5 * 60)
                                if draftClassPreparingLead != snapped {
                                    draftClassPreparingLead = snapped
                                }
                            }
                        ),
                        in: 5 * 60 ... 60 * 60,
                        onEditingChanged: { editing in
                            if !editing, let value = draftClassPreparingLead {
                                store.classPreparingLeadTime = value
                                draftClassPreparingLead = nil
                            }
                        }
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

    private func formatMinutes(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        return "\(minutes) 分鐘"
    }

    /// Snap a raw slider value to the nearest multiple of `step`.
    private static func snap(_ value: TimeInterval, step: TimeInterval) -> TimeInterval {
        (value / step).rounded() * step
    }
}

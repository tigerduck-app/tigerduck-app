#if DEBUG
import Observation
import SwiftUI
import UserNotifications

/// Developer-only screen for the debug time override. Reached from the
/// bottom of Settings; the entry point itself is also `#if DEBUG` so
/// production users never see it. Strings are hardcoded English on purpose
/// (no need to localize a debug menu into 50+ languages).
struct DebugSettingsView: View {
    @State private var viewModel = DebugSettingsViewModel()

    var body: some View {
        Form {
            Section("Time override") {
                Toggle("Use fake time", isOn: Binding(
                    get: { viewModel.enabled },
                    set: { viewModel.setEnabled($0) }
                ))

                DatePicker(
                    "Date & time",
                    selection: Binding(
                        get: { viewModel.draftInstant },
                        set: { viewModel.setDraftInstant($0) }
                    ),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .disabled(!viewModel.enabled)

                Picker("Mode", selection: Binding(
                    get: { viewModel.frozen },
                    set: { viewModel.setFrozen($0) }
                )) {
                    Text("Frozen").tag(true)
                    Text("Ticking").tag(false)
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.enabled)
            }

            Section("Effective now") {
                Text(viewModel.effectiveNow.formatted(date: .complete, time: .standard))
                    .font(.system(.body, design: .monospaced))
            }
        }
        .navigationTitle("Time override")
        .task { await viewModel.observeEffectiveNow() }
    }
}

struct DebugNotificationsView: View {
    @State private var viewModel = DebugNotificationsViewModel()

    var body: some View {
        Form {
            Section {
                Button("Send fake local notification") {
                    Task { await viewModel.sendSimulatedPushNow() }
                }
                if let status = viewModel.lastSimulatedPushStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Fires a local lock-screen / banner notification ~3 s from now. This is NOT a Live Activity — the Dynamic Island appears automatically when the fake clock enters a class window above. Backend APNs pushes use the real wall clock and cannot honor the fake-time override.")
            }
        }
        .navigationTitle("Notifications")
    }
}

@MainActor
@Observable
final class DebugNotificationsViewModel {
    private(set) var lastSimulatedPushStatus: String?

    /// Fires a local notification ~3 s from real-now to simulate what a
    /// backend APNs push would look like. Backend pushes can't honor the
    /// debug clock (the server has no idea time is faked), so this exists
    /// purely so QA can visually confirm a "push arrived" while the LA /
    /// widget pipeline is running under a fake-clock override.
    func sendSimulatedPushNow() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                lastSimulatedPushStatus = "Authorization denied"
                return
            }
        case .denied:
            lastSimulatedPushStatus = "Authorization denied — enable in Settings"
            return
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = "Simulated push"
        content.body = "Fake push fired at \(AppClock.now().formatted(date: .omitted, time: .standard)) (app clock)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        let request = UNNotificationRequest(
            identifier: "debug-simulated-push-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        do {
            try await center.add(request)
            lastSimulatedPushStatus = "Scheduled — arrives in ~3 s (real time)"
        } catch {
            lastSimulatedPushStatus = "Failed: \(error.localizedDescription)"
        }
    }
}
#endif

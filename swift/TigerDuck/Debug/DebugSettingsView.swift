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
                ForEach(DebugNotificationsViewModel.kinds) { kind in
                    Button(kind.id) {
                        Task { await viewModel.sendSimulatedPush(kind) }
                    }
                }
                if let status = viewModel.lastSimulatedPushStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Each fires a local lock-screen / banner notification ~3 s from now, in the same thread as the real one, so it lands in that kind's stack. This is NOT a Live Activity — the Dynamic Island appears automatically when the fake clock enters a class window above. Backend APNs pushes use the real wall clock and cannot honor the fake-time override.")
            }
        }
        .navigationTitle("Notifications")
    }
}

@MainActor
@Observable
final class DebugNotificationsViewModel {
    private(set) var lastSimulatedPushStatus: String?

    /// One kind of notification, and so one stack: what the real one says, and the thread
    /// iOS stacks it by.
    struct Kind: Identifiable {
        /// The button's label.
        let id: String
        let threadIdentifier: String
        let title: String
        let body: () -> String
        var userInfo: [String: Any] = [:]
    }

    /// One per stack. Classes, homework and bulletins come from the server, so their thread is
    /// the server's `thread-id` (its push channel, tigerduck-backend `server/push/`) and their
    /// wording follows its copy; mail is posted on the device by `MailNotifier`.
    static let kinds: [Kind] = {
        var kinds = [
            Kind(id: "Send class reminder", threadIdentifier: "course",
                 title: "上課提醒：Preview Course", body: { "10 分鐘後上課 · TR-412" }),
            Kind(id: "Send homework reminder", threadIdentifier: "assignment",
                 title: "Assignment reminder: Preview Course",
                 body: { "24 hours left! Preview Course \"Preview Assignment\"" }),
        ]
        #if os(iOS)
        // No uid, so a tap opens the inbox rather than a mail that does not exist.
        kinds.append(Kind(id: "Send new mail", threadIdentifier: MailConstants.notificationThread,
                          title: "Preview mail", body: { "Debug Menu" },
                          userInfo: ["kind": MailConstants.notificationKind, "folder": MailConstants.inbox]))
        #endif
        kinds.append(Kind(id: "Send bulletin (Other)", threadIdentifier: "bulletin", title: "Simulated push",
                          body: { "Fake push fired at \(AppClock.now().formatted(date: .omitted, time: .standard)) (app clock)" }))
        return kinds
    }()

    /// Fires a local notification ~3 s from real-now to simulate what a
    /// backend APNs push would look like. Backend pushes can't honor the
    /// debug clock (the server has no idea time is faked), so this exists
    /// purely so QA can visually confirm a "push arrived" while the LA /
    /// widget pipeline is running under a fake-clock override — and which
    /// stack it arrived in.
    func sendSimulatedPush(_ kind: Kind) async {
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
        content.title = kind.title
        content.body = kind.body()
        content.threadIdentifier = kind.threadIdentifier
        content.userInfo = kind.userInfo
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

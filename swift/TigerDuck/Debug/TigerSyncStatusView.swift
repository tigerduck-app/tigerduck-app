#if DEBUG && os(iOS)
import SwiftUI
import UserNotifications

/// Developer-only push diagnostics. Reached from Settings → Developer →
/// TigerSync status; the entry point and this file are both `#if DEBUG` so
/// Release builds never see either. Strings are hardcoded English on
/// purpose (no need to localize a debug menu into 50+ languages).
///
/// The user-facing TigerSync screen (`CloudSyncSettingsView`) keeps only
/// device-registration status, the latest error and the device ID — the
/// things a normal user needs. Everything here is the raw `PushDiagnostic`
/// behind that: including `isStarted` and `resolvedServerURL`, which
/// nothing else in the UI surfaces.
struct TigerSyncStatusView: View {
    @Environment(AppState.self) private var appState
    @State private var snapshot: PushDiagnostic?
    @State private var refreshTimer: Timer?

    var body: some View {
        Form {
            if let s = snapshot {
                Section("PushCoordinator") {
                    LabeledContent("Started") { Text(s.isStarted ? "true" : "false") }
                    LabeledContent("Live Activities enabled") { Text(s.liveActivitiesEnabled ? "true" : "false") }
                    LabeledContent("Notification auth status") { Text(notificationStatusText(s.notificationAuthStatus)) }
                }

                Section("Registration") {
                    LabeledContent("PTS token length") { Text("\(s.registration.ptsTokenLength)") }
                    LabeledContent("Device token length") { Text("\(s.registration.deviceTokenLength)") }
                }

                Section("Identity") {
                    LabeledContent("Device ID") {
                        Text(s.uuid)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    LabeledContent("Server URL") {
                        Text(s.resolvedServerURL.absoluteString)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } else {
                Section {
                    Text("Loading…").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("TigerSync status")
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

    private func refreshSnapshot() async {
        snapshot = await appState.pushCoordinator.currentSnapshot()
    }

    private func notificationStatusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not determined"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }
}
#endif

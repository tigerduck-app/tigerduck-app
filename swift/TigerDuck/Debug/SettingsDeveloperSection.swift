#if DEBUG
import Defaults
import SwiftData
import SwiftUI

struct SettingsDeveloperSection: View {
    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    @Environment(\.modelContext) private var modelContext
    @AppStorage(ScreenCaptureProtectionDebugFlag.userDefaultsKey)
    private var disableScreenCaptureProtection = false

    var body: some View {
        Section("Developer") {
            NavigationLink("Time override") {
                DebugSettingsView()
            }
            NavigationLink("Notifications") {
                DebugNotificationsView()
            }
            NavigationLink("Server failure simulation") {
                DebugServerFailureView()
            }
            #if os(iOS)
            NavigationLink("Triggers") {
                TriggersDebugView()
            }
            NavigationLink("TigerSync status") {
                TigerSyncStatusView()
            }
            NavigationLink("Email") {
                DevMailServerView()
            }
            #endif
            Toggle("Disable screen-capture protection", isOn: $disableScreenCaptureProtection)

            Button {} label: {
                VStack(alignment: .leading) {
                    Text("Long press to erase everything and restart")
                        .foregroundStyle(.red)
                    Text("Wipes all data, accounts (NTUST, Moodle, library), caches, and preferences. Keeps only the API endpoint override.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onLongPressGesture(minimumDuration: 1) {
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                #endif
                eraseEverything()
            }
        }
    }

    private func eraseEverything() {
        guard let app else { return }
        SignOutPlan.school(app).run()
        app.library.logout()
        #if os(iOS)
        MailAccountManager.shared.logout()
        DevMailServerSettings.shared.resetToSchoolServer()
        #endif

        CacheFolders.app.removeEverything()

        SecureStore.removeAll(preserving: [DebugEndpointStore.keychainKey])

        // Batch-delete through the live container rather than removing the
        // store file; the container is still mounted and every view is
        // holding queries against it.
        try? modelContext.delete(model: SDCourse.self)
        try? modelContext.delete(model: SDAssignment.self)
        try? modelContext.delete(model: SDAnnouncement.self)
        try? modelContext.delete(model: SDCalendarEvent.self)
        try? modelContext.save()

        AppUserDefaults.standard.removePersistentDomain(
            forName: Bundle.main.bundleIdentifier!
        )
        Defaults.removeAll()

        try? FileManager.default.removeItem(at: OutboxFiles.defaultDirectory())

        app.hasCompletedOnboarding = false
        Defaults[.hasCompletedOnboarding] = false
    }
}
#endif

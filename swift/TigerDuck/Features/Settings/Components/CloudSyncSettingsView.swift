import Defaults
import SwiftUI

struct CloudSyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Default(.cloudSyncEnabled) private var syncEnabled
    @Default(.syncCourses) private var syncCourses
    @Default(.syncCourseColors) private var syncCourseColors
    @Default(.syncCourseNames) private var syncCourseNames
    @Default(.syncAssignments) private var syncAssignments

    var body: some View {
        Form {
            Section {
                Toggle("Cross-device sync", isOn: $syncEnabled)
                    .onChange(of: syncEnabled) { _, newValue in
                        appState.cloudSyncEnabled = newValue
                    }
            } footer: {
                Text(String(localized: "settings_sync_brief_description"))
            }

            if syncEnabled {
                Section("Sync options") {
                    Toggle("Assignments", isOn: $syncAssignments)

                    NavigationLink {
                        classTableSyncOptions
                    } label: {
                        HStack {
                            Text("Class table")
                            Spacer()
                            let count = [syncCourses, syncCourseColors, syncCourseNames].filter { $0 }.count
                            Text("\(count)/3")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        appState.backgroundSync()
                    } label: {
                        Label(String(localized: "cloud_sync_sync_now"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } else {
                Section {
                    Label(
                        String(localized: "settings_sync_disabled_note"),
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                Link(destination: AppURLs.learnMoreBackend) {
                    Label(String(localized: "settings_learn_more_backend"), systemImage: "server.rack")
                }
                Link(destination: AppURLs.privacyPolicy) {
                    Label(String(localized: "onboarding_privacy_policy_label"), systemImage: "hand.raised.fill")
                }
                Link(destination: AppURLs.deleteAccount) {
                    Label(String(localized: "onboarding_privacy_delete_account_label"), systemImage: "trash")
                }
            }
        }
        .navigationTitle("Cross-device sync")
    }

    private var classTableSyncOptions: some View {
        Form {
            Section {
                Toggle("Courses", isOn: $syncCourses)
                Toggle("Course colours", isOn: $syncCourseColors)
                Toggle("Custom course names", isOn: $syncCourseNames)
            } footer: {
                Text("Choose which class table data to sync across your devices.")
            }
        }
        .navigationTitle("Class table sync")
    }
}

import SwiftUI

struct MoodleNotificationSettingsView: View {
    @State private var settings: MoodleNotificationSettings

    init(settings: MoodleNotificationSettings) {
        _settings = State(initialValue: settings)
    }

    var body: some View {
        Group {
            if let matrix = settings.matrix {
                list(matrix)
            } else {
                MoodleFirstLoadView(failure: settings.loadFailure) { await settings.load() }
            }
        }
        .navigationTitle(String(localized: "moodle_notification_settings_title"))
        .inlineNavigationTitle()
        .task { await settings.load() }
        .alert(settings.saveFailure ?? "", isPresented: Binding(
            get: { settings.saveFailure != nil },
            set: { if !$0 { settings.saveFailure = nil } }
        )) {}
    }

    private func list(_ matrix: MoodleNotificationMatrix) -> some View {
        List {
            Section {
                Picker(String(localized: "moodle_notification_settings_title"), selection: $settings.method) {
                    ForEach(matrix.methods) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ForEach(matrix.components) { component in
                Section(component.name) {
                    ForEach(component.preferences) { preference in
                        Toggle(preference.name, isOn: Binding(
                            get: { settings.isOn(preference) },
                            set: { settings.set($0, for: preference) }
                        ))
                        .disabled(!settings.canChange(preference))
                    }
                }
            }
        }
    }
}

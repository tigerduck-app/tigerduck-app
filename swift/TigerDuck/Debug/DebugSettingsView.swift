#if DEBUG
import SwiftUI

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
                    selection: $viewModel.draftInstant,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .disabled(!viewModel.enabled)

                Picker("Mode", selection: $viewModel.frozen) {
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

            Section {
                HStack {
                    Button("Reset", role: .destructive) {
                        viewModel.reset()
                    }
                    Spacer()
                    Button("Apply") {
                        viewModel.apply()
                    }
                    .disabled(!viewModel.enabled)
                }
            }
        }
        .navigationTitle("Time override")
        .task { await viewModel.observeEffectiveNow() }
    }
}
#endif

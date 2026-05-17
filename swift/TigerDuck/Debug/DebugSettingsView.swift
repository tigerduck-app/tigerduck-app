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
#endif

#if DEBUG
import SwiftUI

struct DebugServerFailureView: View {
    private let simulator = ServerFailureSimulator.shared

    var body: some View {
        Form {
            ForEach(ServerKind.allCases) { server in
                Section(server.label) {
                    Picker("Behaviour", selection: Binding(
                        get: { simulator.failure(for: server) },
                        set: { simulator.failures[server] = $0 }
                    )) {
                        ForEach(SimulatedFailure.allCases) { failure in
                            Text(failure.label).tag(failure)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        Image(systemName: server.icon)
                            .foregroundStyle(statusColor(for: server))
                        Text("Last status: \(statusText(for: server))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Button("Reset all to Normal") {
                    simulator.failures.removeAll()
                }
                Button("Reset server statuses") {
                    ServerStatusTracker.shared.statuses.removeAll()
                }
            }
        }
        .navigationTitle("Server failure simulation")
    }

    private func statusColor(for server: ServerKind) -> Color {
        switch ServerStatusTracker.shared.status(for: server) {
        case .unknown: .gray
        case .ok: .green
        case .failed: .red
        }
    }

    private func statusText(for server: ServerKind) -> String {
        switch ServerStatusTracker.shared.status(for: server) {
        case .unknown: "Unknown"
        case .ok: "OK"
        case .failed: "Failed"
        }
    }
}
#endif

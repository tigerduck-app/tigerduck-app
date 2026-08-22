import SwiftUI

struct ServerStatusIcons: View {
    var servers: [ServerKind]

    private let tracker = ServerStatusTracker.shared

    var body: some View {
        let current = tracker.statuses
        HStack(spacing: 4) {
            ForEach(servers) { server in
                Image(systemName: server.icon)
                    .font(.caption2)
                    .foregroundStyle(color(for: current[server] ?? .unknown))
                    .accessibilityLabel(Text(verbatim: "\(server.label): \(statusLabel(current[server] ?? .unknown))"))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: current.count)
    }

    private func color(for status: ServerStatus) -> Color {
        switch status {
        case .unknown: .gray
        case .ok: .green
        case .failed: .red
        }
    }

    private func statusLabel(_ status: ServerStatus) -> String {
        switch status {
        case .unknown: "Unknown"
        case .ok: "OK"
        case .failed: "Failed"
        }
    }
}

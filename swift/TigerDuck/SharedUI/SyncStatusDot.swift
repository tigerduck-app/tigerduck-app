import Defaults
import SwiftUI

/// The one status mark in a page header. Colour is the worst known state
/// of the sources the page depends on (red > green); grey means nothing
/// has reported yet or the source is switched off, and never wins. While
/// a fetch is running the dot becomes a spinning ring. Tapping it lists
/// every source with its own state.
struct SyncStatusDot: View {
    var servers: [ServerKind]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetails = false
    @State private var spinning = false

    private let tracker = ServerStatusTracker.shared
    private let session = NTUSTSessionManager.shared

    /// Worst-of reduction, ignoring `.unknown` (grey) unless nothing else
    /// is known. A session-level error counts as a failure.
    static func summary(loadingState: LoadingState, statuses: [ServerStatus]) -> ServerStatus {
        if case .error = loadingState { return .failed }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.ok) { return .ok }
        return .unknown
    }

    private var isLoading: Bool { session.loadingState == .loading }

    private var summary: ServerStatus {
        Self.summary(loadingState: session.loadingState, statuses: servers.map { tracker.status(for: $0) })
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            ZStack {
                if isLoading {
                    ring.transition(.scale.combined(with: .opacity))
                } else {
                    Circle()
                        .fill(Self.color(summary))
                        .frame(width: 10, height: 10)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: isLoading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isLoading ? String(localized: "sync_status_syncing") : Self.statusText(summary)))
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            details.presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var ring: some View {
        if reduceMotion {
            ProgressView().controlSize(.mini).tint(Self.color(summary))
        } else {
            Circle()
                .trim(from: 0.2, to: 1)
                .stroke(Self.color(summary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
                .onAppear { spinning = true }
                .onDisappear { spinning = false }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "sync_status_title"))
                .font(.headline)
            if isLoading {
                Label(String(localized: "sync_status_syncing"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                let status = tracker.status(for: server)
                HStack(spacing: 8) {
                    Circle().fill(Self.color(status)).frame(width: 8, height: 8)
                    Label(Self.serverName(server), systemImage: server.icon)
                    Spacer(minLength: 16)
                    Text(Self.statusText(server: server, status: status))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if case .error(let message) = session.loadingState {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 240, alignment: .leading)
    }

    private static func color(_ status: ServerStatus) -> Color {
        switch status {
        case .unknown: .gray
        case .ok: .green
        case .failed: .red
        }
    }

    private static func serverName(_ server: ServerKind) -> String {
        switch server {
        case .moodle: String(localized: "calendar_source_moodle")
        case .courseSelection: String(localized: "feature_course_selection")
        case .backend: String(localized: "cloud_sync_title")
        }
    }

    private static func statusText(server: ServerKind, status: ServerStatus) -> String {
        if server == .backend, !Defaults[.cloudSyncEnabled] {
            return String(localized: "settings_sync_status_off")
        }
        return statusText(status)
    }

    private static func statusText(_ status: ServerStatus) -> String {
        switch status {
        case .ok: String(localized: "sync_status_ok")
        case .failed: String(localized: "sync_status_failed")
        case .unknown: String(localized: "bulletin_push_status_unknown")
        }
    }
}

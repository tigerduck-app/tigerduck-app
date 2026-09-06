import Defaults
import SwiftUI

/// The one status mark in a page header. Colour is the worst known state
/// of the sources the page depends on (red > green); grey means nothing
/// has reported yet or the source is switched off, and never wins. While
/// a fetch is running the dot becomes a spinning ring. Tapping it lists
/// every source with its own state. After a second with no change, no
/// tap and no open popover the dot fades so it stops competing with the
/// page title.
struct SyncStatusDot: View {
    struct Source: Identifiable {
        let id: String
        let icon: String
        let name: String
        let status: ServerStatus
        let text: String
    }

    private enum Mode {
        case servers([ServerKind])
        case single(Source, isLoading: Bool)
    }

    private let mode: Mode

    /// App-wide sync sources, read live from the trackers.
    init(servers: [ServerKind]) {
        mode = .servers(servers)
    }

    /// One page-local source (the library session, say) the page tracks
    /// itself.
    init(status: ServerStatus, label: String, icon: String, text: String, isLoading: Bool = false) {
        mode = .single(
            Source(id: label, icon: icon, name: label, status: status, text: text),
            isLoading: isLoading
        )
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetails = false
    @State private var spinning = false
    @State private var dimmed = false
    @State private var idleTask: Task<Void, Never>?

    private let tracker = ServerStatusTracker.shared
    private let session = NTUSTSessionManager.shared

    static let idleDelay: Duration = .seconds(1)
    /// Low enough to read as "background", high enough that red vs green
    /// still tells apart at a glance.
    static let idleOpacity = 0.5

    /// Worst-of reduction, ignoring `.unknown` (grey) unless nothing else
    /// is known. A session-level error counts as a failure.
    static func summary(loadingState: LoadingState, statuses: [ServerStatus]) -> ServerStatus {
        if case .error = loadingState { return .failed }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.ok) { return .ok }
        return .unknown
    }

    private var isLoading: Bool {
        switch mode {
        case .servers: session.loadingState == .loading
        case .single(_, let isLoading): isLoading
        }
    }

    private var sources: [Source] {
        switch mode {
        case .servers(let servers):
            servers.map { server in
                let status = tracker.status(for: server)
                return Source(
                    id: server.id, icon: server.icon, name: Self.serverName(server),
                    status: status, text: Self.statusText(server: server, status: status)
                )
            }
        case .single(let source, _):
            [source]
        }
    }

    private var summary: ServerStatus {
        switch mode {
        case .servers: Self.summary(loadingState: session.loadingState, statuses: sources.map(\.status))
        case .single(let source, _): source.status
        }
    }

    private var errorMessage: String? {
        if case .servers = mode, case .error(let message) = session.loadingState { return message }
        return nil
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isLoading)
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? Self.idleOpacity : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: dimmed)
        .accessibilityLabel(Text(isLoading ? String(localized: "sync_status_syncing") : Self.statusText(summary)))
        .popover(isPresented: $showDetails, arrowEdge: .top) {
            details.presentationCompactAdaptation(.popover)
        }
        .onAppear(perform: restartIdleTimer)
        .onChange(of: summary) { _, _ in restartIdleTimer() }
        .onChange(of: isLoading) { _, _ in restartIdleTimer() }
        .onChange(of: showDetails) { _, _ in restartIdleTimer() }
        .onDisappear { idleTask?.cancel() }
    }

    /// Any change or interaction brings the dot back to full strength;
    /// a quiet second with the popover closed fades it again. A running
    /// fetch never fades — the ring is the progress indicator.
    private func restartIdleTimer() {
        idleTask?.cancel()
        dimmed = false
        guard !showDetails, !isLoading else { return }
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            dimmed = true
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
                .animation(.linear(duration: 0.6).repeatForever(autoreverses: false), value: spinning)
                .onAppear { spinning = true }
                .onDisappear { spinning = false }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                row(color: .clear, icon: "arrow.triangle.2.circlepath",
                    name: String(localized: "sync_status_syncing"), text: nil)
            }
            ForEach(sources) { source in
                row(color: Self.color(source.status), icon: source.icon, name: source.name, text: source.text)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .font(.subheadline)
        .padding(12)
    }

    /// Dot, icon, name, state. The icon sits in a fixed-width slot so
    /// symbols of different widths still leave every name on one column.
    private func row(color: Color, icon: String, name: String, text: String?) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(name)
            if let text {
                Spacer(minLength: 12)
                Text(text).foregroundStyle(.secondary)
            }
        }
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

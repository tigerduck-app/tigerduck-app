import Defaults
import SwiftUI

/// The one status mark in a page header — a bare dot, with no backing.
///
/// Colour is the worst known state
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
    /// Optional so the dot still renders in a preview with no `AppState`
    /// injected, where "signed out" is the conservative read.
    @Environment(AppState.self) private var appState: AppState?
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

    private var isSignedIn: Bool { appState?.authService.hasStoredCredentials ?? false }

    /// Cloud sync switched off: the row reads grey / "Off" rather than
    /// whatever the tracker happens to be holding.
    ///
    /// Reading the setting rather than the tracker is what keeps the row
    /// honest — the tracker is process-wide, so the OK from the last sync
    /// before the switch went off would otherwise sit there green. The
    /// signed-out case never reaches here; `body` draws nothing at all.
    private func isOff(_ server: ServerKind) -> Bool {
        server == .backend && !Defaults[.cloudSyncEnabled]
    }

    private var sources: [Source] {
        switch mode {
        case .servers(let servers):
            servers.map { server in
                let off = isOff(server)
                let status = off ? ServerStatus.unknown : tracker.status(for: server)
                return Source(
                    id: server.id, icon: server.icon, name: Self.serverName(server),
                    status: status,
                    text: off
                        ? String(localized: "settings_sync_status_off")
                        : Self.statusText(status)
                )
            }
        case .single(let source, _):
            [source]
        }
    }

    private var summary: ServerStatus {
        switch mode {
        case .servers(let servers):
            // Nothing was asked to sync, so the NTUST session's own state is
            // not this dot's business either — grey, not red.
            servers.allSatisfy(isOff)
                ? .unknown
                : Self.summary(loadingState: session.loadingState, statuses: sources.map(\.status))
        case .single(let source, _):
            source.status
        }
    }

    /// "Off" rather than "Unknown" when every source is switched off — the
    /// aggregate grey has a reason, and VoiceOver should give it.
    private var accessibilityStatusText: String {
        if isLoading { return String(localized: "sync_status_syncing") }
        if case .servers(let servers) = mode, servers.allSatisfy(isOff) {
            return String(localized: "settings_sync_status_off")
        }
        return Self.statusText(summary)
    }

    private var errorMessage: String? {
        if case .servers = mode, case .error(let message) = session.loadingState { return message }
        return nil
    }

    /// Signed out there is nothing syncing and nothing to report, so the
    /// header carries no mark at all rather than a grey one that has to
    /// explain itself. On the pages that need an account the content
    /// already says so in full, and the one page that works signed out
    /// (bulletins are public) never had a status worth reading there.
    ///
    /// Only `.servers` is account-gated. A `.single` source is page-local
    /// and tracks something the page signed into itself, like the library.
    @ViewBuilder
    var body: some View {
        if case .servers = mode, !isSignedIn {
            EmptyView()
        } else {
            dot
        }
    }

    private var dot: some View {
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
            // The 28pt frame is the tap target, not a backing: the mark
            // itself stays 10pt. Without it the dot would be a 10pt hit
            // area, well under the 44pt minimum.
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isLoading)
        }
        .buttonStyle(.plain)
        .opacity(dimmed ? Self.idleOpacity : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: dimmed)
        .accessibilityLabel(Text(accessibilityStatusText))
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

    private static func statusText(_ status: ServerStatus) -> String {
        switch status {
        case .ok: String(localized: "sync_status_ok")
        case .failed: String(localized: "sync_status_failed")
        case .unknown: String(localized: "bulletin_push_status_unknown")
        }
    }
}

import Defaults
import SwiftUI

struct SyncStatusDot: View {
    struct Source: Identifiable {
        let id: String
        let icon: String
        let name: String
        let status: ServerStatus
        let text: String
    }

    enum LastSynced: Equatable {
        case schoolData
        case at(Date?)
        case hidden
    }

    private enum Mode {
        case servers([ServerKind])
        case single(Source, isLoading: Bool)
    }

    private let mode: Mode
    private let lastSynced: LastSynced

    init(servers: [ServerKind], lastSynced: LastSynced) {
        mode = .servers(servers)
        self.lastSynced = lastSynced
    }

    init(
        status: ServerStatus, label: String, icon: String, text: String, isLoading: Bool = false,
        lastSynced: LastSynced
    ) {
        mode = .single(
            Source(id: label, icon: icon, name: label, status: status, text: text),
            isLoading: isLoading
        )
        self.lastSynced = lastSynced
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(AppEnvironment.self) private var app: AppEnvironment?
    /// Observed rather than read through `Defaults[...]`. `isMinimal` feeds
    /// `sources`, which the body reads, and a bare subscript is a read
    /// SwiftUI never subscribes to -- so switching sync off left the row on
    /// whatever word it already had until something unrelated forced a
    /// redraw, which is the opposite of what `isMinimal` is for.
    @Default(.cloudSyncEnabled) private var cloudSyncEnabled
    @Default(.schoolDataSyncedAt) private var schoolDataSyncedAt
    @State private var showDetails = false
    @State private var spinning = false
    @State private var dimmed = false
    @State private var idleTask: Task<Void, Never>?

    private let tracker = ServerStatusTracker.shared
    private let session = NTUSTSessionManager.shared

    static let idleDelay: Duration = .seconds(1)
    static let idleOpacity = 0.5

    static func summary(loadingState: LoadingState, statuses: [ServerStatus]) -> ServerStatus {
        SyncStatusText.summary(loadingState: loadingState, statuses: statuses)
    }

    private var isLoading: Bool {
        switch mode {
        case .servers: session.loadingState == .loading
        case .single(_, let isLoading): isLoading
        }
    }

    private var isSignedIn: Bool { app?.authService.hasStoredCredentials ?? false }

    private func isMinimal(_ server: ServerKind) -> Bool {
        server == .backend && !cloudSyncEnabled
    }

    private var sources: [Source] {
        switch mode {
        case .servers(let servers):
            servers.map { server in
                let status = tracker.status(for: server)
                return Source(
                    id: server.id, icon: server.icon, name: SyncStatusText.serverName(server),
                    status: status,
                    text: isMinimal(server) && status == .ok
                        ? String(localized: "sync_status_minimal")
                        : Self.statusText(status)
                )
            }
        case .single(let source, _):
            [source]
        }
    }

    private var summary: ServerStatus {
        switch mode {
        case .servers:
            Self.summary(loadingState: session.loadingState, statuses: sources.map(\.status))
        case .single(let source, _):
            source.status
        }
    }

    private var accessibilityStatusText: String {
        let syncing = String(localized: "sync_status_syncing")
        if case .single(let source, _) = mode { return isLoading ? "\(syncing), \(source.text)" : source.text }
        if isLoading { return syncing }
        if case .servers(let servers) = mode,
           servers.allSatisfy(isMinimal), summary == .ok {
            return String(localized: "sync_status_minimal")
        }
        return Self.statusText(summary)
    }

    private var errorMessage: String? {
        guard case .servers(let servers) = mode else { return nil }
        if case .error(let message) = session.loadingState { return message }
        return servers.lazy.compactMap { tracker.note(for: $0) }.first
    }

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
                    mark.transition(.scale.combined(with: .opacity))
                }
            }
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
    private var mark: some View {
        if differentiateWithoutColor, let glyph = Self.glyph(summary) {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SyncStatusText.color(summary))
        } else {
            Circle()
                .fill(SyncStatusText.color(summary))
                .frame(width: 10, height: 10)
        }
    }

    @ViewBuilder
    private var ring: some View {
        if reduceMotion {
            ProgressView().controlSize(.mini).tint(SyncStatusText.color(summary))
        } else {
            Circle()
                .trim(from: 0.2, to: 1)
                .stroke(SyncStatusText.color(summary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.6).repeatForever(autoreverses: false), value: spinning)
                .onAppear { spinning = true }
                .onDisappear { spinning = false }
        }
    }

    private var details: some View {
        SyncStatusDetails(isLoading: isLoading, sources: sources, showsLastSynced: lastSynced != .hidden,
                          lastSyncedDate: lastSyncedDate, errorMessage: errorMessage)
    }

    private var lastSyncedDate: Date? {
        switch lastSynced {
        case .schoolData: schoolDataSyncedAt
        case .at(let date): date
        case .hidden: nil
        }
    }

    static func ageText(_ syncedAt: Date?, now: Date) -> String { SyncStatusText.ageText(syncedAt, now: now) }
    static func glyph(_ status: ServerStatus) -> String? { SyncStatusText.glyph(status) }
    static func statusText(_ status: ServerStatus) -> String { SyncStatusText.statusText(status) }
}

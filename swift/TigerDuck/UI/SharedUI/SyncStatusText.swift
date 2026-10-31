import SwiftUI

/// The words, colours and glyphs the sync status dot shows for a status.
enum SyncStatusText {
    static func summary(loadingState: LoadingState, statuses: [ServerStatus]) -> ServerStatus {
        if case .error = loadingState { return .failed }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.ok) { return .ok }
        return .unknown
    }

    static func ageText(_ syncedAt: Date?, now: Date) -> String {
        guard let syncedAt else { return String(localized: "sync_status_never_updated") }
        let seconds = max(0, now.timeIntervalSince(syncedAt))
        switch seconds {
        case ..<60:
            return String(localized: "sync_status_just_now")
        case ..<3600:
            return String(format: String(localized: "sync_status_minutes_ago_short"), Int(seconds / 60))
        case ..<86_400:
            return String(format: String(localized: "sync_status_hours_ago_short"), Int(seconds / 3600))
        default:
            return String(format: String(localized: "sync_status_days_ago_short"), Int(seconds / 86_400))
        }
    }

    static func color(_ status: ServerStatus) -> Color {
        switch status {
        case .unknown: .gray
        case .ok: .green
        case .failed: .red
        }
    }

    static func glyph(_ status: ServerStatus) -> String? {
        switch status {
        case .unknown: nil
        case .ok: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    static func serverName(_ server: ServerKind) -> String {
        switch server {
        case .moodle: String(localized: "calendar_source_moodle")
        case .courseSelection: String(localized: "feature_course_selection")
        case .scoreSystem: String(localized: "sync_status_score_system")
        case .backend: String(localized: "cloud_sync_title")
        }
    }

    static func statusText(_ status: ServerStatus) -> String {
        switch status {
        case .ok: String(localized: "sync_status_ok")
        case .failed: String(localized: "sync_status_failed")
        case .unknown: String(localized: "bulletin_push_status_unknown")
        }
    }
}

/// The sync status dot's popover: each server's status, when the data was last updated, and the
/// last error.
struct SyncStatusDetails: View {
    let isLoading: Bool
    let sources: [SyncStatusDot.Source]
    let showsLastSynced: Bool
    let lastSyncedDate: Date?
    let errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                row(color: .clear, icon: "arrow.triangle.2.circlepath",
                    name: String(localized: "sync_status_syncing"), text: nil)
            }
            ForEach(sources) { source in
                row(color: SyncStatusText.color(source.status), icon: source.icon, name: source.name, text: source.text)
            }
            if showsLastSynced {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    row(color: .clear, icon: "clock", name: String(localized: "sync_status_last_updated"),
                        text: SyncStatusText.ageText(lastSyncedDate, now: context.date))
                }
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
}

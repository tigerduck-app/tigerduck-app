import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ScheduleStore

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: store.snapshot?.loggedIn == true
                          ? "person.crop.circle.fill.badge.checkmark"
                          : "person.crop.circle.badge.exclamationmark")
                    Text(loginText)
                        .font(.subheadline)
                }
                HStack {
                    Image(systemName: "clock")
                    Text(lastSyncedText)
                        .font(.subheadline)
                }
                Button {
                    store.requestSync(force: true)
                } label: {
                    Label(String(localized: "watch_settings_sync_now"),
                          systemImage: "arrow.clockwise")
                }
            }
            Section {
                Text(versionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "watch_settings"))
    }

    private var loginText: String {
        store.snapshot?.loggedIn == true
            ? String(localized: "watch_settings_signed_in")
            : String(localized: "watch_settings_signed_out")
    }

    private var lastSyncedText: String {
        guard let ms = store.snapshot?.syncedAtMs, ms > 0 else {
            return String(localized: "watch_last_synced_never")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }
}

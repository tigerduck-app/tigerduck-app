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
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(lastSyncedText(now: context.date))
                            .font(.subheadline)
                    }
                }
                Button {
                    store.requestSync(force: true)
                } label: {
                    Label(store.language.string("watch_settings_sync_now"),
                          systemImage: "arrow.clockwise")
                }
            }
            Section {
                Text(versionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(store.language.string("watch_settings"))
    }

    private var loginText: String {
        store.snapshot?.loggedIn == true
            ? store.language.string("watch_settings_signed_in")
            : store.language.string("watch_settings_signed_out")
    }

    private func lastSyncedText(now: Date) -> String {
        let language = store.language
        guard let ms = store.snapshot?.syncedAtMs, ms > 0 else {
            return language.string("watch_last_synced_never")
        }
        let synced = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let ageSec = max(0, Int(now.timeIntervalSince(synced)))
        let pretty: String
        if ageSec < 60 {
            pretty = language.string("watch_just_now")
        } else if ageSec < 3_600 {
            pretty = language.format("watch_relative_minutes_ago_short", ageSec / 60)
        } else if ageSec < 86_400 {
            pretty = language.format("watch_relative_hours_ago_short", ageSec / 3_600)
        } else {
            pretty = language.format("watch_relative_days_ago_short", ageSec / 86_400)
        }
        return language.format("watch_last_synced_relative", pretty)
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }
}

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: ScheduleStore
    @Environment(\.locale) private var locale

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

    // `locale:` is required so the lookup honors the in-app language pushed
    // from the phone (via WatchTheme's `.environment(\.locale)`); without it
    // `String(localized:)` reads `Bundle.main.preferredLocalizations`, i.e.
    // the watch system locale, and the row mixes languages.
    private func lastSyncedText(now: Date) -> String {
        guard let ms = store.snapshot?.syncedAtMs, ms > 0 else {
            return String(localized: "watch_last_synced_never", locale: locale)
        }
        let synced = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let ageSec = max(0, Int(now.timeIntervalSince(synced)))
        let pretty: String
        if ageSec < 60 {
            pretty = String(localized: "watch_just_now", locale: locale)
        } else if ageSec < 3_600 {
            let fmt = String(localized: "watch_relative_minutes_ago_short", locale: locale)
            pretty = String(format: fmt, locale: locale, ageSec / 60)
        } else if ageSec < 86_400 {
            let fmt = String(localized: "watch_relative_hours_ago_short", locale: locale)
            pretty = String(format: fmt, locale: locale, ageSec / 3_600)
        } else {
            let fmt = String(localized: "watch_relative_days_ago_short", locale: locale)
            pretty = String(format: fmt, locale: locale, ageSec / 86_400)
        }
        let wrapper = String(localized: "watch_last_synced_relative", locale: locale)
        return String(format: wrapper, locale: locale, pretty)
    }

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }
}

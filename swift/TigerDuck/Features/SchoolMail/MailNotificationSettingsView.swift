#if os(iOS)
import SwiftUI
import UIKit

struct MailNotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsDenied = false
    @State private var records: [MailCheckRecord] = []
    private let account: MailAccountManager

    init(account: MailAccountManager? = nil) {
        self.account = account ?? .shared
    }

    static func notificationsToggleIsEnabled(isLoggedIn: Bool, authFailed: Bool) -> Bool {
        isLoggedIn && !authFailed
    }

    static func settingsRowIsEnabled(isLoggedIn: Bool) -> Bool {
        isLoggedIn
    }

    @MainActor
    static func notificationsBinding(for account: MailAccountManager) -> Binding<Bool> {
        @Bindable var account = account
        return $account.notificationsEnabled
    }

    var body: some View {
        List {
            Section {
                Toggle(
                    String(localized: "school_mail_settings_notifications"),
                    isOn: Self.notificationsBinding(for: account)
                )
                .disabled(!Self.notificationsToggleIsEnabled(
                    isLoggedIn: account.isLoggedIn, authFailed: account.authFailed))
                if notificationsDenied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label(String(localized: "permission_not_granted_tap_settings"), systemImage: "gear")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                    Text(String(localized: "school_mail_settings_notifications_hint"))
                    Text(String(localized: "school_mail_settings_background_refresh_hint"))
                }
            }

            Section(String(localized: "school_mail_settings_diagnostics")) {
                if records.isEmpty {
                    Text(String(localized: "school_mail_settings_no_checks"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(MailCheckOutcome.displayText(forStored: record.result))
                            Text("\(record.date.fullDateString) \(record.date.timeString) · \(MailCheckTrigger.displayText(forStored: record.trigger))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "school_mail_notification_settings_title"))
        .onAppear { records = account.prefs.diagnostics }
        .task { notificationsDenied = await MailNotificationPermission.isDenied() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { notificationsDenied = await MailNotificationPermission.isDenied() }
        }
    }
}
#endif

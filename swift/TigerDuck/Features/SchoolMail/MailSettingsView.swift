#if os(iOS)
import SwiftUI
import UIKit

/// 信箱設定 (design doc §6.5): notifications, the display name, diagnostics, the guide.
struct MailSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsDenied = false
    @State private var displayNameDraft = ""
    @State private var records: [MailCheckRecord] = []
    private let account = MailAccountManager.shared

    /// Turning notifications on schedules a background refresh. After a rejected password
    /// `MailBackgroundRefresh.shouldRescheduleAfterHandling` refuses to reschedule, and §7.4
    /// forbids retrying the password at all — so offering the switch there is offering
    /// something the app will not do. Signed out, there is nothing to check either.
    static func notificationsToggleIsEnabled(isLoggedIn: Bool, authFailed: Bool) -> Bool {
        isLoggedIn && !authFailed
    }

    var body: some View {
        @Bindable var account = account
        List {
            Section {
                Toggle(String(localized: "school_mail_settings_notifications"), isOn: $account.notificationsEnabled)
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

            Section {
                TextField(String(localized: "school_mail_settings_display_name"), text: $displayNameDraft)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onSubmit { account.displayName = displayNameDraft.mailNonEmpty }
            } header: {
                Text(String(localized: "school_mail_settings_display_name"))
            } footer: {
                Text(String(localized: "school_mail_settings_display_name_hint"))
            }

            Section(String(localized: "school_mail_settings_diagnostics")) {
                if records.isEmpty {
                    Text(String(localized: "school_mail_settings_no_checks"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.result)
                            Text("\(record.date.fullDateString) \(record.date.timeString) · \(record.trigger)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                NavigationLink(String(localized: "school_mail_use_other_app")) { MailGuideView() }
            }
        }
        .navigationTitle(String(localized: "school_mail_account_title"))
        .onAppear {
            displayNameDraft = account.displayName ?? ""
            records = account.prefs.diagnostics
        }
        .onDisappear { account.displayName = displayNameDraft.mailNonEmpty }
        .task { notificationsDenied = await MailNotificationPermission.isDenied() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { notificationsDenied = await MailNotificationPermission.isDenied() }
        }
    }
}
#endif

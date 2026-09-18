#if os(iOS)
import SwiftUI
import UIKit

/// 校園信箱通知: the new-mail switch and the check log, reached from Settings → 通知
/// alongside the app's other notification screens rather than from 信箱設定.
///
/// The switch was **moved** here out of `MailSettingsView`, not mirrored: one screen owns
/// `MailAccountManager.notificationsEnabled`, so there is no second copy of the control
/// that could show a different state than the one the background refresh actually reads.
struct MailNotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsDenied = false
    @State private var records: [MailCheckRecord] = []
    private let account: MailAccountManager

    /// Injectable purely so tests can drive a throwaway account instead of the app's real
    /// singleton (which reaches the real `UserDefaults`). Every caller in the app uses the
    /// default.
    init(account: MailAccountManager = .shared) {
        self.account = account
    }

    /// Turning notifications on schedules a background refresh. After a rejected password
    /// `MailBackgroundRefresh.shouldRescheduleAfterHandling` refuses to reschedule, and §7.4
    /// forbids retrying the password at all — so offering the switch there is offering
    /// something the app will not do. Signed out, there is nothing to check either.
    static func notificationsToggleIsEnabled(isLoggedIn: Bool, authFailed: Bool) -> Bool {
        isLoggedIn && !authFailed
    }

    /// Whether the Settings row that opens this screen is tappable. Signed out there is no
    /// mailbox to be notified about, so the row stays visible but dimmed and inert — no
    /// explanatory subtitle, by the owner's choice: the 校園信箱 account row further up the
    /// same screen already says the account is signed out.
    ///
    /// Demo mode is signed in as far as this is concerned — `isLoggedIn` is the student ID
    /// being present, which a demo login sets like any other.
    static func settingsRowIsEnabled(isLoggedIn: Bool) -> Bool {
        isLoggedIn
    }

    /// The binding the switch below is built from, lifted out so a test can drive the real
    /// control the way a tap does rather than poke the model behind it and hope the view
    /// is wired to the same property.
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
                            Text(record.result)
                            Text("\(record.date.fullDateString) \(record.date.timeString) · \(record.trigger)")
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

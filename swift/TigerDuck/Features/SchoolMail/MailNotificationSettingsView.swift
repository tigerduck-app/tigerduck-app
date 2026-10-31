#if os(iOS)
import SwiftUI
import UIKit
import TigerDuckCore

///
struct MailNotificationSettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationsDenied = false
    @State private var records: [MailCheckRecord] = []
    @State private var editingRule: MailMuteRule?
    private let account: MailAccountManager

    /// Injectable purely so tests can drive a throwaway account instead of the app's real
    /// singleton (which reaches the real `UserDefaults`). Every caller in the app uses the
    /// default.
    /// Optional-defaulted-to-`nil` rather than `= .shared`: a default argument expression is
    /// type-checked in a nonisolated context, and `MailAccountManager.shared` is main-actor
    /// isolated, so spelling the singleton there is an isolation violation in the Swift 6
    /// language mode. Resolving it in this (main-actor) body keeps the seam identical.
    init(account: MailAccountManager? = nil) {
        self.account = account ?? .shared
    }

    /// Turning notifications on schedules a background refresh. After a rejected password
    /// `MailBackgroundRefresh.shouldRescheduleAfterHandling` refuses to reschedule, and the
    /// password is never retried (repeated failures lock the school account and its Wi-Fi), so
    /// the switch would offer something the app will not do. Signed out, there is nothing to
    /// check either.
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

    /// The pickers edit a time of day; a fixed January day keeps a daylight saving change out of it.
    static func pickerDate(minutes: Int, calendar: Calendar = TaipeiTime.calendar) -> Date {
        let day = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? day
    }

    static func minutes(of date: Date, calendar: Calendar = TaipeiTime.calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private static func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { pickerDate(minutes: minutes.wrappedValue) }, set: { minutes.wrappedValue = Self.minutes(of: $0) })
    }

    private static func presetBinding(_ preset: MailMutePreset, in presets: Binding<Set<MailMutePreset>>) -> Binding<Bool> {
        Binding(
            get: { presets.wrappedValue.contains(preset) },
            set: { isOn in
                if isOn { presets.wrappedValue.insert(preset) } else { presets.wrappedValue.remove(preset) }
            }
        )
    }

    @MainActor
    static func save(_ rule: MailMuteRule, in account: MailAccountManager) {
        if let index = account.muteSettings.rules.firstIndex(where: { $0.id == rule.id }) {
            account.muteSettings.rules[index] = rule
        } else {
            account.muteSettings.rules.append(rule)
        }
    }

    var body: some View {
        @Bindable var account = self.account
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

            Group {
                quietHoursSection(quietHours: $account.muteSettings.quietHours)
                Section(String(localized: "school_mail_filters")) {
                    ForEach(MailMutePreset.allCases, id: \.self) { preset in
                        Toggle(preset.title, isOn: Self.presetBinding(preset, in: $account.muteSettings.presets))
                    }
                }
                customRulesSection
            }
            .disabled(!account.notificationsEnabled)

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
        .sheet(item: $editingRule) { rule in
            MailMuteRuleSheet(rule: rule, isNew: !account.muteSettings.rules.contains { $0.id == rule.id }) {
                Self.save($0, in: account)
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

    private func quietHoursSection(quietHours: Binding<MailQuietHours>) -> some View {
        Section(String(localized: "school_mail_quiet_hours")) {
            Toggle(String(localized: "school_mail_quiet_hours"), isOn: quietHours.isEnabled)
            if quietHours.wrappedValue.isEnabled {
                DatePicker(String(localized: "school_mail_quiet_hours_start"),
                           selection: Self.timeBinding(quietHours.start), displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, TaipeiTime.timeZone)
                DatePicker(String(localized: "school_mail_quiet_hours_end"),
                           selection: Self.timeBinding(quietHours.end), displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, TaipeiTime.timeZone)
                NavigationLink {
                    MailQuietDaysView(weekdays: quietHours.weekdays)
                } label: {
                    LabeledContent(String(localized: "school_mail_quiet_hours_days"),
                                   value: MailQuietDaysView.summary(quietHours.wrappedValue.weekdays))
                }
            }
        }
    }

    private var customRulesSection: some View {
        Section(String(localized: "school_mail_filter_custom")) {
            ForEach(account.muteSettings.rules) { rule in
                Button { editingRule = rule } label: { MailMuteRuleRow(rule: rule) }
            }
            .onDelete { account.muteSettings.rules.remove(atOffsets: $0) }
            Button(String(localized: "school_mail_filter_add")) {
                editingRule = MailMuteRule(field: .from, op: .contains, value: "")
            }
        }
    }
}
#endif

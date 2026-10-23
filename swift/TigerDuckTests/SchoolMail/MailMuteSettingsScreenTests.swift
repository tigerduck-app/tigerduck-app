#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct MailMuteSettingsScreenTests {
    private func show(_ account: MailAccountManager) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1600)
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            MailNotificationSettingsView(account: account)
        })
        window.isHidden = false
        return window
    }

    @Test func theRepeatRowSaysEveryDayOrListsTheDays() {
        #expect(MailQuietDaysView.summary(Set(1...7)) == String(localized: "school_mail_quiet_hours_every_day"))
        let some = [String(localized: "weekday_mon_caption"), String(localized: "weekday_wed_caption"),
                    String(localized: "weekday_fri_caption")].joined(separator: " ")
        #expect(MailQuietDaysView.summary([6, 2, 4]) == some)
    }

    @Test func theLastDayCannotBeTurnedOff() {
        #expect(MailQuietDaysView.toggling(3, in: [3]) == [3])
        #expect(MailQuietDaysView.toggling(3, in: [2, 3]) == [2])
        #expect(MailQuietDaysView.toggling(4, in: [3]) == [3, 4])
    }

    @Test func thePickersKeepTheTimeOfDay() {
        for minutes in [0, 7 * 60, 23 * 60 + 59] {
            #expect(MailNotificationSettingsView.minutes(of: MailNotificationSettingsView.pickerDate(minutes: minutes)) == minutes)
        }
    }

    @Test func theSheetSavesOnlyARuleWithText() {
        #expect(!MailMuteRuleSheet.canSave(MailMuteRule(field: .from, op: .contains, value: "  ")))
        #expect(MailMuteRuleSheet.canSave(MailMuteRule(field: .from, op: .contains, value: "x")))
    }

    @Test("the page shows quiet hours with their times and days, the presets and a custom rule as field, operator and text")
    func thePageShowsTheRules() async throws {
        try await withAccessibilityAutomation {
            let h = MailAccountManagerTests.harness()
            await h.manager.login(studentID: "B10000000", password: "pw")
            h.manager.muteSettings.quietHours.isEnabled = true
            h.manager.muteSettings.rules = [MailMuteRule(field: .from, op: .contains, value: "newsletter")]
            let window = try show(h.manager)
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            let bulletin = String(localized: "school_mail_filter_preset_bulletin")
            try await waitUntil { accessibilityElement(labeled: bulletin, in: root) != nil }

            let texts = exposedAccessibilityTexts(in: root)
            for key in ["school_mail_quiet_hours_start", "school_mail_quiet_hours_end",
                        "school_mail_filter_preset_bulletin", "school_mail_filter_preset_moodle_submission",
                        "school_mail_filter_add"] {
                let label = String(localized: String.LocalizationValue(key))
                #expect(texts.contains { $0.hasPrefix(label) }, "\(label) in \(texts)")
            }
            let days = [String(localized: "school_mail_quiet_hours_days"), String(localized: "school_mail_quiet_hours_every_day")]
            #expect(texts.contains { text in days.allSatisfy(text.contains) }, "\(texts)")
            let rule = [String(localized: "school_mail_filter_field_from"), String(localized: "school_mail_filter_op_contains"),
                        "newsletter"]
            #expect(texts.contains { text in rule.allSatisfy(text.contains) }, "\(texts)")
        }
    }

    @Test("with new mail notifications off the rules are greyed out, and with quiet hours off their times are gone")
    func theRulesFollowTheNotificationsSwitch() async throws {
        try await withAccessibilityAutomation {
            let h = MailAccountManagerTests.harness()
            await h.manager.login(studentID: "B10000000", password: "pw")
            h.manager.notificationsEnabled = false
            let window = try show(h.manager)
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            let bulletin = String(localized: "school_mail_filter_preset_bulletin")
            try await waitUntil { accessibilityElement(labeled: bulletin, in: root) != nil }

            #expect(accessibilityElement(labeled: bulletin, in: root)?.accessibilityTraits.contains(.notEnabled) == true)
            #expect(accessibilityElement(labeled: String(localized: "school_mail_quiet_hours_start"), in: root) == nil)
        }
    }
}
#endif

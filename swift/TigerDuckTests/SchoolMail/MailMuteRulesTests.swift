#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

struct MailMuteRulesTests {
    private static func mail(
        from address: String? = "office@mail.ntust.edu.tw", name: String? = "Office", to: [String]? = nil,
        cc: [String]? = nil, subject: String? = "Hello"
    ) -> MailSummary {
        MailSummary(uid: 1, fromName: name, fromAddress: address, to: to, cc: cc, subject: subject, date: nil,
                    isSeen: false, isAnswered: false, isDeleted: false, size: nil, hasAttachments: false,
                    isExternal: false)
    }

    /// A time in the device's time zone, which is the one quiet hours use. 2026-10-23 is a Friday.
    private static func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private static func rule(_ field: MailMuteRule.Field, _ op: MailMuteRule.Operator, _ value: String) -> MailMuteRule {
        MailMuteRule(field: field, op: op, value: value)
    }

    // MARK: Rules

    @Test func fromContainsLooksAtTheNameAndTheAddressIgnoringCase() {
        let mail = Self.mail(from: "News@Example.com", name: "Campus Newsletter")
        #expect(Self.rule(.from, .contains, "newsletter").matches(mail))
        #expect(Self.rule(.from, .contains, "example.COM").matches(mail))
        #expect(!Self.rule(.from, .contains, "digest").matches(mail))
    }

    @Test func fromIsComparesTheAddressOnly() {
        let mail = Self.mail(from: "News@Example.com", name: "Campus Newsletter")
        #expect(Self.rule(.from, .is, "news@example.com").matches(mail))
        #expect(Self.rule(.from, .is, " NEWS@EXAMPLE.COM ").matches(mail))
        #expect(!Self.rule(.from, .is, "Campus Newsletter").matches(mail))
        #expect(!Self.rule(.from, .is, "news@example").matches(mail))
    }

    @Test func toOrCcLooksAtEveryRecipient() {
        let mail = Self.mail(to: ["\"Class 3A\" <class3a@mail.ntust.edu.tw>"], cc: ["advisor@mail.ntust.edu.tw"])
        #expect(Self.rule(.toOrCc, .contains, "class 3a").matches(mail))
        #expect(Self.rule(.toOrCc, .contains, "ADVISOR").matches(mail))
        #expect(Self.rule(.toOrCc, .is, "Class3A@mail.ntust.edu.tw").matches(mail))
        #expect(Self.rule(.toOrCc, .is, "advisor@mail.ntust.edu.tw").matches(mail))
        #expect(!Self.rule(.toOrCc, .is, "Class 3A").matches(mail))
        #expect(!Self.rule(.toOrCc, .contains, "class").matches(Self.mail()))
    }

    @Test func subjectContainsOrIsTheWholeSubject() {
        let mail = Self.mail(subject: "Weekly Digest: October")
        #expect(Self.rule(.subject, .contains, "digest").matches(mail))
        #expect(Self.rule(.subject, .is, "weekly digest: october").matches(mail))
        #expect(!Self.rule(.subject, .is, "Weekly Digest").matches(mail))
        #expect(!Self.rule(.subject, .contains, "digest").matches(Self.mail(subject: nil)))
    }

    @Test func anEmptyValueMatchesNothing() {
        #expect(!Self.rule(.subject, .contains, " ").matches(Self.mail()))
        #expect(!Self.rule(.subject, .is, "").matches(Self.mail(subject: "")))
    }

    @Test func aMailMatchingTwoRulesIsMutedOnce() {
        var settings = MailMuteSettings()
        settings.rules = [Self.rule(.from, .contains, "office"), Self.rule(.subject, .contains, "hello")]
        #expect(settings.mutes(Self.mail(), arrivedAt: Self.at(day: 23, 12)))
        settings.rules = []
        #expect(!settings.mutes(Self.mail(), arrivedAt: Self.at(day: 23, 12)))
    }

    @Test func theBulletinPresetMutesItsSenderOnly() {
        var settings = MailMuteSettings()
        let bulletin = Self.mail(from: "Bulletin@mail.ntust.edu.tw", subject: "Any notice")
        #expect(!settings.mutes(bulletin, arrivedAt: Self.at(day: 23, 12)))
        settings.presets = [.bulletin]
        #expect(settings.mutes(bulletin, arrivedAt: Self.at(day: 23, 12)))
        #expect(!settings.mutes(Self.mail(), arrivedAt: Self.at(day: 23, 12)))
    }

    @Test func theMoodlePresetNeedsBothItsSenderAndAReceiptSubject() {
        let preset = MailMutePreset.moodleSubmission
        #expect(preset.matches(Self.mail(from: "noreply@mail.ntust.edu.tw", subject: "Course: 您已經繳交 Homework 1")))
        #expect(preset.matches(Self.mail(from: "noreply@mail.ntust.edu.tw",
                                         subject: "Course: You have submitted your assignment submission for HW1")))
        #expect(!preset.matches(Self.mail(from: "noreply@mail.ntust.edu.tw", subject: "New forum post")))
        #expect(!preset.matches(Self.mail(from: "someone@mail.ntust.edu.tw", subject: "您已經繳交 Homework 1")))
    }

    @Test func settingsSurviveEncoding() throws {
        var settings = MailMuteSettings()
        settings.quietHours = MailQuietHours(isEnabled: true, start: 22 * 60 + 30, end: 6 * 60, weekdays: [2, 3])
        settings.presets = [.moodleSubmission]
        settings.rules = [Self.rule(.toOrCc, .is, "a@b.c")]
        let decoded = try JSONDecoder().decode(MailMuteSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test func storedSettingsMissingAFieldKeepTheRest() throws {
        let stored = Data(#"""
            {"quietHours":{"isEnabled":true,"end":360},"rules":[{"field":"subject","op":"is","value":"Digest"}]}
            """#.utf8)
        let decoded = try JSONDecoder().decode(MailMuteSettings.self, from: stored)
        #expect(decoded.quietHours == MailQuietHours(isEnabled: true, start: 23 * 60, end: 360, weekdays: Set(1...7)))
        #expect(decoded.presets.isEmpty)
        #expect(decoded.rules.map(\.field) == [.subject])
        #expect(decoded.rules.map(\.op) == [.is])
        #expect(decoded.rules.map(\.value) == ["Digest"])
        #expect(try JSONDecoder().decode(MailMuteSettings.self, from: Data("{}".utf8)) == MailMuteSettings())
    }

    // MARK: Quiet hours

    @Test func aWindowInsideOneDay() {
        let quiet = MailQuietHours(isEnabled: true, start: 13 * 60, end: 14 * 60)
        #expect(!quiet.contains(Self.at(day: 23, 12, 59), calendar: .current))
        #expect(quiet.contains(Self.at(day: 23, 13), calendar: .current))
        #expect(quiet.contains(Self.at(day: 23, 13, 59), calendar: .current))
        #expect(!quiet.contains(Self.at(day: 23, 14), calendar: .current))
    }

    @Test func aWindowAcrossMidnight() {
        let quiet = MailQuietHours(isEnabled: true)
        #expect(quiet.contains(Self.at(day: 23, 23, 30), calendar: .current))
        #expect(quiet.contains(Self.at(day: 24, 6, 59), calendar: .current))
        #expect(!quiet.contains(Self.at(day: 24, 7), calendar: .current))
        #expect(!quiet.contains(Self.at(day: 23, 22, 59), calendar: .current))
    }

    @Test func aWindowBelongsToTheDayItStartsOn() {
        // Friday only: Friday night into Saturday morning is quiet, Saturday night is not.
        let quiet = MailQuietHours(isEnabled: true, weekdays: [6])
        #expect(quiet.contains(Self.at(day: 23, 23), calendar: .current))
        #expect(quiet.contains(Self.at(day: 24, 3), calendar: .current))
        #expect(!quiet.contains(Self.at(day: 24, 23), calendar: .current))
        #expect(!quiet.contains(Self.at(day: 23, 3), calendar: .current))
        // Sunday only: the Saturday-to-Sunday wrap of the weekday numbers.
        let sunday = MailQuietHours(isEnabled: true, weekdays: [1])
        #expect(sunday.contains(Self.at(day: 26, 2), calendar: .current))
        #expect(!sunday.contains(Self.at(day: 25, 2), calendar: .current))
    }

    @Test func offOrEmptyWindowsQuietNothing() {
        #expect(!MailQuietHours().contains(Self.at(day: 23, 23, 30), calendar: .current))
        #expect(!MailQuietHours(isEnabled: true, start: 60, end: 60).contains(Self.at(day: 23, 1), calendar: .current))
        #expect(!MailQuietHours(isEnabled: true, weekdays: []).contains(Self.at(day: 23, 23, 30), calendar: .current))
    }

    // MARK: Checks

    private static func message(uid: UInt32, from: String = "office@mail.ntust.edu.tw", arrivedAt: Date) -> FakeMailClient.Message {
        var message = FakeMailClient.message(uid: uid, from: from)
        message.summary.arrivedAt = arrivedAt
        return message
    }

    @Test func aMutedMailIsPassedOverAndNotCounted() async {
        let h = MailCheckerTests.harness(inbox: [
            Self.message(uid: 3, from: "bulletin@mail.ntust.edu.tw", arrivedAt: Self.at(day: 23, 12)),
            Self.message(uid: 4, arrivedAt: Self.at(day: 23, 12)),
        ], marker: 3)
        h.prefs.muteSettings.presets = [.bulletin]
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(h.center.requests.map(\.identifier) == ["school-mail-1-4"])
        #expect(h.prefs.inboxNextUID == 5)
    }

    @Test func mailFromInsideTheWindowNeverNotifiesFromALaterCheck() async {
        let h = MailCheckerTests.harness(inbox: [
            Self.message(uid: 3, arrivedAt: Self.at(day: 23, 23, 30)),
            Self.message(uid: 4, arrivedAt: Self.at(day: 24, 6, 50)),
        ], marker: 3)
        h.prefs.muteSettings.quietHours.isEnabled = true
        #expect(await h.checker.check(trigger: .backgroundTask) == .noNewMail)
        #expect(h.center.requests.isEmpty)
        #expect(h.prefs.inboxNextUID == 5)

        await h.fake.update { $0.folders["INBOX"]?.append(Self.message(uid: 5, arrivedAt: Self.at(day: 24, 7, 10))) }
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(h.center.requests.map(\.identifier) == ["school-mail-1-5"])
    }

    @Test func aMutedMailStaysPassedOverWhenAnEarlierFailureRetriesAfterTheRuleIsLifted() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 3
        prefs.muteSettings.presets = [.bulletin]
        let fake = FakeMailClient(folders: ["INBOX": [
            Self.message(uid: 3, arrivedAt: Self.at(day: 23, 12)),
            Self.message(uid: 4, from: "bulletin@mail.ntust.edu.tw", arrivedAt: Self.at(day: 23, 12)),
        ]])
        let center = RejectingNotificationCenter(rejecting: ["school-mail-1-3"])
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { fake }, onAuthFailure: {})
        #expect(await checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(prefs.inboxNextUID == 3)

        prefs.muteSettings.presets = []
        center.stopRejecting()
        #expect(await checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(center.accepted == ["school-mail-1-3"])
        #expect(prefs.inboxNextUID == 5)
    }

    @MainActor @Test func signingOutForgetsTheRules() async {
        let h = MailAccountManagerTests.harness()
        await h.manager.login(studentID: "B10000000", password: "pw")
        h.manager.muteSettings.presets = [.bulletin]
        #expect(h.prefs.muteSettings.presets == [.bulletin])
        h.manager.logout()
        #expect(h.manager.muteSettings == MailMuteSettings())
        #expect(h.prefs.muteSettings == MailMuteSettings())
    }

    @Test func theStoredRulesRoundTripAndReset() {
        let suiteName = "MailMuteRulesTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let prefs = DefaultsMailPreferences(defaults: suite)
        #expect(prefs.muteSettings == MailMuteSettings())
        prefs.muteSettings.rules = [Self.rule(.subject, .contains, "ad")]
        #expect(DefaultsMailPreferences(defaults: suite).muteSettings.rules.map(\.value) == ["ad"])
        prefs.inboxMutedUIDs = MailMutedUIDs(uidValidity: 7, uids: [4, 9])
        #expect(DefaultsMailPreferences(defaults: suite).inboxMutedUIDs == MailMutedUIDs(uidValidity: 7, uids: [4, 9]))
        prefs.reset()
        #expect(prefs.muteSettings == MailMuteSettings())
        #expect(prefs.inboxMutedUIDs == nil)
    }
}
#endif

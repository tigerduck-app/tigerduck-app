#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MailSendHoldScreenTests {
    enum Look: String, CaseIterable {
        case light, dark, largestText
    }

    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private static func show(_ view: some View, look: Look) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.overrideUserInterfaceStyle = look == .dark ? .dark : .light
        if look == .largestText { window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        let still = view.tint(AppPreferences().accentColor).transaction { $0.disablesAnimations = true }
        window.rootViewController = UIHostingController(rootView: still)
        window.isHidden = false
        return window
    }

    private struct ListScene: View {
        let hold: MailSendHold
        private static let subjects = ["期末專題分組", "Re: Lab report draft", "停修申請公告", "借閱到期提醒", "Club fair volunteers"]

        var body: some View {
            List(Self.subjects, id: \.self) { subject in
                Text(verbatim: subject)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TigerDuckTheme.Spacing.lg)
                    .glassCard()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.backgroundPrimary)
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                MailListBottomBar(hold: hold, showsCompose: true, accentColor: AppPreferences().accentColor) {}
            }
        }
    }

    @Test("the bar sits beside the compose button, whole, with Undo as a button", arguments: Look.allCases)
    func theBarSitsBesideTheComposeButton(look: Look) async throws {
        try await withAccessibilityAutomation {
            let rig = MailSendHoldTests.rig()
            rig.hold.hold(await MailSendHoldTests.written(MailComposeViewModelTests.fake()))
            defer { rig.hold.undo() }
            let window = try Self.show(ListScene(hold: rig.hold), look: look)
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            let undoLabel = String(localized: "school_mail_undo_send")
            try await waitUntil { accessibilityElement(labeled: undoLabel, in: root) != nil }
            try await Task.sleep(for: .milliseconds(600))
            window.saveSnapshot(as: "mail-send-hold-\(Self.language)-\(look.rawValue)")

            let undo = try #require(accessibilityElement(labeled: undoLabel, in: root))
            let text = try #require(accessibilityElement(labeled: String(localized: "school_mail_sending_hold"), in: root))
            let compose = try #require(accessibilityElement(labeled: String(localized: "school_mail_compose"), in: root))
            #expect(undo.accessibilityTraits.contains(.button))
            #expect(undo.accessibilityFrame.height.rounded() >= 44, "\(undo.accessibilityFrame)")
            // Frames that only touch meet a fraction of a point apart in floating point.
            let undoFrame = undo.accessibilityFrame.insetBy(dx: 0.5, dy: 0.5)
            #expect(!undoFrame.intersects(compose.accessibilityFrame), "\(undoFrame) \(compose.accessibilityFrame)")
            #expect(!undoFrame.intersects(text.accessibilityFrame), "\(undoFrame) \(text.accessibilityFrame)")
            for frame in [undo.accessibilityFrame, text.accessibilityFrame, compose.accessibilityFrame] {
                #expect(window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame)")
            }
        }
    }

    @Test("Undo reopens the composer with the recipient, subject, body and attachment", arguments: Look.allCases)
    func theReopenedComposerKeepsTheDraft(look: Look) async throws {
        try await withAccessibilityAutomation {
            let rig = MailSendHoldTests.rig()
            rig.hold.hold(await MailSendHoldTests.written(MailComposeViewModelTests.fake()))
            rig.hold.undo()
            let reopened = try #require(rig.hold.takeReopened())
            let window = try Self.show(MailComposeView(model: reopened, hold: rig.hold), look: look)
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            try await waitUntil { exposedAccessibilityTexts(in: root).contains { $0.contains("期末報告") } }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "mail-send-undone-\(Self.language)-\(look.rawValue)")

            let texts = exposedAccessibilityTexts(in: root)
            var shown = ["a@mail.ntust.edu.tw", "期末報告"]
            if look != .largestText { shown += ["老師好，附上報告。", "報告.pdf"] }
            for text in shown {
                #expect(texts.contains { $0.contains(text) }, "\(text) in \(texts)")
            }
        }
    }

    @Test func sendHoldsTheMailWithoutAConfirmation() async throws {
        try await withAccessibilityAutomation {
            let rig = MailSendHoldTests.rig()
            let model = await MailSendHoldTests.written(MailComposeViewModelTests.fake())
            let window = try Self.show(MailComposeView(model: model, hold: rig.hold), look: .light)
            defer {
                window.isHidden = true
                rig.hold.undo()
            }
            let root = try #require(window.rootViewController?.view)
            let send = String(localized: "school_mail_send")
            // On iOS 26 the toolbar item's host view carries the label too, and only the button activates.
            let sendButton = {
                exposedAccessibilityElements(in: root).first { $0.accessibilityLabel == send && $0.accessibilityTraits.contains(.button) }
            }
            try await waitUntil { sendButton() != nil }

            #expect(try #require(sendButton()).accessibilityActivate())
            try await waitUntil { rig.hold.held != nil }
            #expect(rig.hold.held?.model === model)
            try await Task.sleep(for: .milliseconds(500))
            #expect(window.rootViewController?.presentedViewController == nil)
            #expect(accessibilityElement(labeled: String(localized: "school_mail_send_confirm_title"), in: window) == nil)
        }
    }
}
#endif

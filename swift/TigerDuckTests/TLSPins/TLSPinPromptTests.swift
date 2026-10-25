#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct TLSPinPromptTests {
    typealias F = TLSPinFixtures

    static let mismatch = TLSPinMismatch(
        setID: "library", host: "api.lib.ntust.edu.tw", domains: ["api.lib.ntust.edu.tw"],
        issuerOrganization: "Sectigo Limited",
        certificates: TLSPinningDelegateTests.libraryChain.map { TLSCertificateSummary(der: Data($0)) },
        acceptedSPKIs: [F.unknownSPKI], anchorSPKI: F.globalRootSPKI
    )

    nonisolated static let styles: [UIUserInterfaceStyle] = [.light, .dark]

    @MainActor
    @Observable
    final class Prompting {
        @ObservationIgnored let engine = F.engine(document: F.promptRootsDocument)
        @ObservationIgnored let defaults = F.defaults()
        @ObservationIgnored let owner = TLSPinPromptOwner()
        @ObservationIgnored var continued = 0
        @ObservationIgnored private(set) var queue: TLSPinMismatchQueue!
        var showsOtherSheet = false

        init() {
            queue = TLSPinMismatchQueue(
                engine: engine, defaults: defaults, clock: { F.now }, afterContinue: { [unowned self] in continued += 1 }
            )
            queue.isForeground = true
        }

        var isQuiet: Bool { isQuiet("library") }

        func isQuiet(_ setID: String) -> Bool {
            defaults.dictionary(forKey: "tlsPinPromptQuietUntil")?[setID] != nil
        }
    }

    /// A page under the prompt, with a sheet of its own as a tab has.
    private struct Page: View {
        @Bindable var prompting: Prompting

        var body: some View {
            Color.clear.sheet(isPresented: $prompting.showsOtherSheet) { Text(verbatim: "Other") }
        }
    }

    /// One window's own scene phase, which the app-wide one does not follow.
    @MainActor
    @Observable
    final class Phase {
        var value: ScenePhase = .active
    }

    private struct Root: View {
        let prompting: Prompting
        let phase: Phase

        var body: some View {
            Page(prompting: prompting)
                .tlsPinPrompt(queue: prompting.queue, owner: prompting.owner)
                .environment(\.scenePhase, phase.value)
        }
    }

    static func window(
        _ prompting: Prompting, style: UIUserInterfaceStyle = .light, height: CGFloat = 874,
        textSize: UIContentSizeCategory? = nil, phase: Phase? = nil
    ) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: Root(prompting: prompting, phase: phase ?? Phase()))
        // Set the way the system setting reaches the app, through the window's traits.
        if let textSize { window.traitOverrides.preferredContentSizeCategory = textSize }
        window.makeKeyAndVisible()
        return window
    }

    /// The window's presented sheet once it shows the prompt's title.
    static func shownSheet(in window: UIWindow) async throws -> UIView {
        let root = try #require(window.rootViewController)
        let title = String(localized: "tls_pin_mismatch_title")
        try await waitUntil {
            root.presentedViewController.map { accessibilityElement(labeled: title, in: $0.view) != nil } == true
        }
        return try #require(root.presentedViewController?.view)
    }

    static func activate(_ label: String, in view: UIView) async throws {
        try await waitUntil { accessibilityElement(labeled: label, in: view) != nil }
        #expect(try #require(accessibilityElement(labeled: label, in: view)).accessibilityActivate())
    }

    static var details: String {
        String(format: String(localized: "tls_pin_mismatch_details"), mismatch.host, mismatch.host)
    }

    @Test("the collapsed sheet has one heading, the host and its issuer, and hides the details", arguments: styles)
    func collapsed(style: UIUserInterfaceStyle) async throws {
        try await withAccessibilityAutomation {
            let prompting = Prompting()
            let window = try Self.window(prompting, style: style)
            defer { window.isHidden = true }
            prompting.queue.report(Self.mismatch)
            let sheet = try await Self.shownSheet(in: window)

            let labels = exposedAccessibilityLabels(in: sheet)
            #expect(labels.contains(String(localized: "tls_pin_mismatch_message")))
            #expect(labels.contains("api.lib.ntust.edu.tw"))
            #expect(labels.contains(String(format: String(localized: "tls_pin_mismatch_issuer"), "Sectigo Limited")))
            #expect(labels.contains(String(localized: "tls_pin_mismatch_show_details")))
            #expect(!labels.contains(Self.details))
            let headings = exposedAccessibilityElements(in: sheet).filter { $0.accessibilityTraits.contains(.header) }
            #expect(Set(headings.compactMap(\.accessibilityLabel)) == [String(localized: "tls_pin_mismatch_title")])
            for button in [String(localized: "action_cancel"), String(localized: "action_continue")] {
                let element = try #require(accessibilityElement(labeled: button, in: sheet))
                #expect(element.accessibilityTraits.contains(.button))
            }
        }
    }

    @Test("Details expands in place to the explanation and View certificate", arguments: styles)
    func expanded(style: UIUserInterfaceStyle) async throws {
        try await withAccessibilityAutomation {
            let prompting = Prompting()
            let window = try Self.window(prompting, style: style)
            defer { window.isHidden = true }
            prompting.queue.report(Self.mismatch)
            let sheet = try await Self.shownSheet(in: window)

            try await Self.activate(String(localized: "tls_pin_mismatch_show_details"), in: sheet)
            try await waitUntil { accessibilityElement(labeled: Self.details, in: sheet) != nil }
            #expect(accessibilityElement(labeled: String(localized: "tls_pin_mismatch_view_certificate"), in: sheet) != nil)
            #expect(window.rootViewController?.presentedViewController?.view === sheet)
        }
    }

    @Test("View certificate lists each served certificate with its fingerprint as text", arguments: styles)
    func certificateList(style: UIUserInterfaceStyle) async throws {
        try await withAccessibilityAutomation {
            let prompting = Prompting()
            // Tall enough that the list builds every section's rows.
            let window = try Self.window(prompting, style: style, height: 1600)
            defer { window.isHidden = true }
            prompting.queue.report(Self.mismatch)
            let sheet = try await Self.shownSheet(in: window)

            try await Self.activate(String(localized: "tls_pin_mismatch_show_details"), in: sheet)
            try await Self.activate(String(localized: "tls_pin_mismatch_view_certificate"), in: sheet)
            let root = String(localized: "tls_certificate_root")
            try await waitUntil { accessibilityElement(labeled: root, in: sheet) != nil }

            let texts = exposedAccessibilityTexts(in: sheet)
            #expect(texts.contains("api.lib.ntust.edu.tw"))
            #expect(texts.contains(String(localized: "tls_certificate_intermediate")))
            for button in [String(localized: "action_cancel"), String(localized: "action_continue")] {
                #expect(accessibilityElement(labeled: button, in: sheet) != nil, "\(button) is gone from the list")
            }
            for certificate in Self.mismatch.certificates {
                #expect(texts.contains { $0.contains(certificate.name) })
                #expect(texts.contains { $0.contains(certificate.sha256Fingerprint) })
                let notBefore = try #require(certificate.notBefore), notAfter = try #require(certificate.notAfter)
                #expect(texts.contains { $0.contains("\(notBefore.fullDateString) – \(notAfter.fullDateString)") })
            }
        }
    }

    @Test("Continue accepts the chain, refreshes and closes the sheet")
    func continueAccepts() async throws {
        try await withAccessibilityAutomation {
            let prompting = Prompting()
            let window = try Self.window(prompting)
            defer { window.isHidden = true }
            prompting.queue.report(Self.mismatch)
            let sheet = try await Self.shownSheet(in: window)

            try await Self.activate(String(localized: "action_continue"), in: sheet)
            try await waitUntil { window.rootViewController?.presentedViewController == nil }
            #expect(prompting.queue.prompt == nil)
            #expect(prompting.engine.acceptances.map(\.setID) == ["library"])
            #expect(prompting.continued == 1)
            #expect(!prompting.isQuiet)
        }
    }

    @Test("Cancel stores nothing, starts the quiet hour and closes the sheet")
    func cancelDeclines() async throws {
        try await withAccessibilityAutomation {
            let prompting = Prompting()
            let window = try Self.window(prompting)
            defer { window.isHidden = true }
            prompting.queue.report(Self.mismatch)
            let sheet = try await Self.shownSheet(in: window)

            try await Self.activate(String(localized: "action_cancel"), in: sheet)
            try await waitUntil { window.rootViewController?.presentedViewController == nil }
            #expect(prompting.queue.prompt == nil)
            #expect(prompting.engine.acceptances.isEmpty)
            #expect(prompting.continued == 0)
            #expect(prompting.isQuiet)
        }
    }

    @Test("closing the sheet outside its buttons, as a swipe down does, is a Cancel")
    func swipeDismissCancels() async throws {
        let prompting = Prompting()
        let window = try Self.window(prompting)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        prompting.queue.report(Self.mismatch)
        try await waitUntil { root.presentedViewController != nil }

        root.dismiss(animated: true)
        try await waitUntil { prompting.queue.prompt == nil }
        #expect(prompting.engine.acceptances.isEmpty)
        #expect(prompting.continued == 0)
        #expect(prompting.isQuiet)
    }

    @Test("a prompt the queue takes back, as the app leaves, closes the sheet with no Cancel")
    func takenBackIsNoCancel() async throws {
        let prompting = Prompting()
        let window = try Self.window(prompting)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        prompting.queue.report(Self.mismatch)
        try await waitUntil { root.presentedViewController != nil }

        prompting.queue.isForeground = false
        try await waitUntil { root.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!prompting.isQuiet)
        #expect(prompting.engine.acceptances.isEmpty)

        prompting.queue.isForeground = true
        try await waitUntil { root.presentedViewController != nil }
        #expect(prompting.queue.prompt == Self.mismatch)
    }

    @Test("at accessibility sizes Continue sits above Cancel, each the sheet's width")
    func stackedAtAccessibilitySizes() async throws {
        try await withAccessibilityAutomation {
            let prompting = Prompting()
            let window = try Self.window(prompting, textSize: .accessibilityExtraLarge)
            defer { window.isHidden = true }
            prompting.queue.report(Self.mismatch)
            let sheet = try await Self.shownSheet(in: window)
            try await Task.sleep(for: .milliseconds(600))

            let cancel = try #require(accessibilityElement(labeled: String(localized: "action_cancel"), in: sheet))
            let proceed = try #require(accessibilityElement(labeled: String(localized: "action_continue"), in: sheet))
            #expect(proceed.accessibilityFrame.maxY <= cancel.accessibilityFrame.minY)
            #expect(abs(proceed.accessibilityFrame.width - cancel.accessibilityFrame.width) < 1)
        }
    }

    static let ntustMismatch = TLSPinMismatch(
        setID: "ntust", host: "moodle2.ntust.edu.tw", domains: ["ntust.edu.tw"], issuerOrganization: "TAIWAN-CA",
        certificates: [], acceptedSPKIs: [F.unknownSPKI], anchorSPKI: F.globalRootSPKI
    )

    @Test("an answer for a prompt the queue has since replaced leaves the newer one alone")
    func aLateAnswerLeavesANewerPrompt() {
        let prompting = Prompting()
        let queue: TLSPinMismatchQueue = prompting.queue
        queue.report(Self.mismatch)
        queue.answer(Self.mismatch, continues: true)
        queue.report(Self.ntustMismatch)
        #expect(queue.prompt == Self.ntustMismatch)

        queue.answer(Self.mismatch, continues: true)
        queue.answer(Self.mismatch, continues: false)
        #expect(queue.prompt == Self.ntustMismatch)
        #expect(prompting.engine.acceptances.map(\.setID) == ["library"])
        #expect(!prompting.isQuiet("ntust"))
    }

    @Test("a window that closes with the prompt up hands it to another window, with no Cancel")
    func aClosingWindowIsNoCancel() async throws {
        let prompting = Prompting()
        let windows = try [Self.window(prompting), Self.window(prompting)]
        defer { windows.forEach { $0.isHidden = true } }
        prompting.queue.report(Self.mismatch)
        func showing() -> [UIWindow] { windows.filter { $0.rootViewController?.presentedViewController != nil } }
        try await waitUntil { !showing().isEmpty }
        let closing = try #require(showing().first)
        let other = try #require(windows.first { $0 !== closing })

        closing.isHidden = true
        closing.rootViewController = nil
        try await waitUntil { other.rootViewController?.presentedViewController != nil }
        #expect(prompting.queue.prompt == Self.mismatch)
        #expect(!prompting.isQuiet)
        #expect(prompting.engine.acceptances.isEmpty)
    }

    @Test("a sheet that opens with the prompt gets the window, and the prompt shows once it closes")
    func aSheetOpeningWithThePrompt() async throws {
        try await withAccessibilityAutomation {
            let prompting = Prompting()
            let window = try Self.window(prompting)
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController)
            try await waitUntil { root.view.window != nil }
            prompting.showsOtherSheet = true
            prompting.queue.report(Self.mismatch)
            try await waitUntil { root.presentedViewController != nil }
            try await Task.sleep(for: .seconds(4))

            prompting.showsOtherSheet = false
            _ = try await Self.shownSheet(in: window)
            #expect(prompting.queue.prompt == Self.mismatch)
            #expect(!prompting.isQuiet)
        }
    }

    @Test("a window going inactive, then to the background, hands the prompt to an active one")
    func anInactiveThenBackgroundedWindowHandsItOver() async throws {
        let prompting = Prompting()
        let phases = [Phase(), Phase()]
        let windows = try phases.map { try Self.window(prompting, phase: $0) }
        defer { windows.forEach { $0.isHidden = true } }
        prompting.queue.report(Self.mismatch)
        func showing() -> [Int] { windows.indices.filter { windows[$0].rootViewController?.presentedViewController != nil } }
        try await waitUntil { showing().count == 1 }
        let hidden = try #require(showing().first)

        phases[hidden].value = .inactive
        try await Task.sleep(for: .milliseconds(300))
        #expect(showing() == [hidden])
        phases[hidden].value = .background
        try await waitUntil { showing() == [1 - hidden] }
        #expect(prompting.queue.prompt == Self.mismatch)
        #expect(!prompting.isQuiet)
    }

    @Test("a window whose scene goes to the background hands the prompt to an active one, with no Cancel")
    func aBackgroundedWindowHandsItOver() async throws {
        let prompting = Prompting()
        let phases = [Phase(), Phase()]
        let windows = try phases.map { try Self.window(prompting, phase: $0) }
        defer { windows.forEach { $0.isHidden = true } }
        prompting.queue.report(Self.mismatch)
        func showing() -> [Int] { windows.indices.filter { windows[$0].rootViewController?.presentedViewController != nil } }
        try await waitUntil { showing().count == 1 }
        let hidden = try #require(showing().first)

        phases[hidden].value = .background
        try await waitUntil { showing() == [1 - hidden] }
        #expect(prompting.queue.prompt == Self.mismatch)
        #expect(!prompting.isQuiet)
        #expect(prompting.engine.acceptances.isEmpty)
    }

    @Test("with two windows open, one shows the prompt")
    func oneWindowShowsIt() async throws {
        let prompting = Prompting()
        let windows = try [Self.window(prompting), Self.window(prompting)]
        defer { windows.forEach { $0.isHidden = true } }
        prompting.queue.report(Self.mismatch)

        func showing() -> Int { windows.filter { $0.rootViewController?.presentedViewController != nil }.count }
        try await waitUntil { showing() > 0 }
        try await Task.sleep(for: .seconds(1))
        #expect(showing() == 1)
    }

    @Test("the prompt waits for a sheet already up in the window, which it would close")
    func waitsForAnOpenSheet() async throws {
        let prompting = Prompting()
        let window = try Self.window(prompting)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        prompting.showsOtherSheet = true
        try await waitUntil { root.presentedViewController != nil }
        let other = root.presentedViewController

        prompting.queue.report(Self.mismatch)
        try await Task.sleep(for: .seconds(1))
        #expect(root.presentedViewController === other)
        #expect(prompting.showsOtherSheet)
        #expect(prompting.owner.holder == nil)

        prompting.showsOtherSheet = false
        try await waitUntil { root.presentedViewController.map { $0 !== other } == true }
        #expect(prompting.owner.holder != nil)
        #expect(prompting.queue.prompt == Self.mismatch)
    }
}
#endif

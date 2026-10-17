#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// What closes before a reminder's assignment page is pushed: every sheet, with the state SwiftUI
/// keeps for it, and neither an alert nor a sheet that refuses a swipe down. Each test shows a
/// window of its own.
@MainActor
struct ModalClosingTests {
    @Observable
    final class Sheets {
        var course = false
        var files = false
        var filesRefuseToClose = false
        var filesKept = false
        var draft = false
        var conflict = false
        var courseDismissals = 0
    }

    private struct Host: View {
        @Bindable var sheets: Sheets

        var body: some View {
            Color.clear
                .sheet(isPresented: $sheets.course, onDismiss: { sheets.courseDismissals += 1 }) {
                    Text("Course").sheet(isPresented: $sheets.files) {
                        Text("Files")
                            .interactiveDismissDisabled(sheets.filesRefuseToClose)
                            .keptOverReminders(sheets.filesKept)
                    }
                }
                .background(Color.clear.sheet(isPresented: $sheets.draft) {
                    Text("Draft").interactiveDismissDisabled()
                })
                .alert("Conflict", isPresented: $sheets.conflict) { Button("Keep") {} }
        }
    }

    /// What `then` was told and found when `closePresentations` ran it.
    private struct AtThen: Equatable {
        let closedAll: Bool
        let isPresenting: Bool
        let course: Bool
        let files: Bool
        let courseDismissals: Int
    }

    private static func show(_ sheets: Sheets) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = UIHostingController(rootView: Host(sheets: sheets))
        window.makeKeyAndVisible()
        return window
    }

    private static func close(_ root: UIViewController, _ sheets: Sheets) async -> AtThen {
        await withCheckedContinuation { done in
            root.closePresentations { closedAll in
                done.resume(returning: AtThen(
                    closedAll: closedAll, isPresenting: root.presentedViewController != nil, course: sheets.course,
                    files: sheets.files, courseDismissals: sheets.courseDismissals
                ))
            }
        }
    }

    /// Home pushes the page from `then`, and pushes at once only when its course sheet's state is
    /// already clear, so the state has to be clear by then, not only afterwards.
    @Test("a sheet and the one over it close, their state cleared, before the page is pushed")
    func sheetsClose() async throws {
        let sheets = Sheets()
        let window = try Self.show(sheets)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        sheets.course = true
        try await waitUntil { root.presentedViewController != nil }
        sheets.files = true
        try await waitUntil { root.presentedViewController?.presentedViewController != nil }

        #expect(await Self.close(root, sheets)
            == AtThen(closedAll: true, isPresenting: false, course: false, files: false, courseDismissals: 1))

        sheets.course = true
        try await waitUntil { root.presentedViewController != nil }
        sheets.course = false
        try await waitUntil { root.presentedViewController == nil }
    }

    @Test("an alert or a sheet that refuses a swipe down stays, and the page is pushed behind it at once")
    func guardedStays() async throws {
        let sheets = Sheets()
        let window = try Self.show(sheets)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)

        sheets.draft = true
        try await waitUntil { root.presentedViewController != nil }
        #expect(await Self.close(root, sheets).closedAll == false)
        #expect(root.presentedViewController != nil)
        #expect(sheets.draft)
        sheets.draft = false
        try await waitUntil { root.presentedViewController == nil }

        sheets.conflict = true
        try await waitUntil { root.presentedViewController is UIAlertController }
        #expect(await Self.close(root, sheets).closedAll == false)
        #expect(root.presentedViewController != nil)
        #expect(sheets.conflict)
        sheets.conflict = false
        try await waitUntil { root.presentedViewController == nil }
    }

    @Test("with nothing up the page is pushed at once")
    func nothingUp() async throws {
        let sheets = Sheets()
        let window = try Self.show(sheets)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)

        #expect(await Self.close(root, sheets)
            == AtThen(closedAll: true, isPresenting: false, course: false, files: false, courseDismissals: 0))
    }

    /// Home's course sheet with a member's mail draft over it: closing the course sheet would take
    /// the draft with it.
    @Test("a sheet that refuses a swipe over another keeps both up, and says so")
    func guardedOverAnother() async throws {
        let sheets = Sheets()
        let window = try Self.show(sheets)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        sheets.filesRefuseToClose = true
        sheets.course = true
        try await waitUntil { root.presentedViewController != nil }
        sheets.files = true
        try await waitUntil { root.presentedViewController?.presentedViewController != nil }

        #expect(await Self.close(root, sheets)
            == AtThen(closedAll: false, isPresenting: true, course: true, files: true, courseDismissals: 0))

        sheets.course = false
        try await waitUntil { root.presentedViewController == nil }
    }

    /// What's New over Home's course sheet: closing it would mark it as seen unread
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/673).
    @Test("a sheet kept over reminders stays, with the one under it, yet still closes on a swipe")
    func keptStays() async throws {
        let sheets = Sheets()
        let window = try Self.show(sheets)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        sheets.filesKept = true
        sheets.course = true
        try await waitUntil { root.presentedViewController != nil }
        sheets.files = true
        try await waitUntil { root.presentedViewController?.presentedViewController.map { !$0.isBeingPresented } == true }

        #expect(root.presentedViewController?.presentedViewController?.isModalInPresentation == false)
        #expect(await Self.close(root, sheets)
            == AtThen(closedAll: false, isPresenting: true, course: true, files: true, courseDismissals: 0))

        sheets.course = false
        try await waitUntil { root.presentedViewController == nil }
    }

    /// The page is pushed from the dismissal's completion, so a close UIKit dropped while a sheet
    /// slides would leave the reminder tap doing nothing.
    @Test("a sheet still sliding up closes once it is up, and then the page is pushed")
    func sheetStillSliding() async throws {
        let sheets = Sheets()
        let window = try Self.show(sheets)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        sheets.course = true
        try await waitUntil { root.presentedViewController?.isBeingPresented == true }

        let told = Told()
        root.closePresentations { told.closedAll = $0 }

        try await waitUntil(timeout: .seconds(10)) { told.closedAll != nil }
        #expect(told.closedAll == true)
        #expect(root.presentedViewController == nil)
        #expect(!sheets.course)
    }

    @Test("a sheet already sliding down is waited out, and then the page is pushed")
    func sheetSlidingDown() async throws {
        let sheets = Sheets()
        let window = try Self.show(sheets)
        defer { window.isHidden = true }
        let root = try #require(window.rootViewController)
        sheets.course = true
        try await waitUntil { root.presentedViewController.map { !$0.isBeingPresented } == true }
        sheets.course = false
        try await waitUntil { root.presentedViewController?.isBeingDismissed == true }

        let told = Told()
        root.closePresentations { told.closedAll = $0 }

        try await waitUntil(timeout: .seconds(10)) { told.closedAll != nil }
        #expect(told.closedAll == true)
        #expect(root.presentedViewController == nil)
    }

    @MainActor
    private final class Told {
        var closedAll: Bool?
    }
}
#endif

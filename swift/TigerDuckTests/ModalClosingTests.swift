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
        var draft = false
        var conflict = false
        var courseDismissals = 0
    }

    private struct Host: View {
        @Bindable var sheets: Sheets

        var body: some View {
            Color.clear
                .sheet(isPresented: $sheets.course, onDismiss: { sheets.courseDismissals += 1 }) {
                    Text("Course").sheet(isPresented: $sheets.files) { Text("Files") }
                }
                .background(Color.clear.sheet(isPresented: $sheets.draft) {
                    Text("Draft").interactiveDismissDisabled()
                })
                .alert("Conflict", isPresented: $sheets.conflict) { Button("Keep") {} }
        }
    }

    /// What `then` found when `closePresentations` ran it.
    private struct AtThen: Equatable {
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
            root.closePresentations {
                done.resume(returning: AtThen(
                    isPresenting: root.presentedViewController != nil, course: sheets.course, files: sheets.files,
                    courseDismissals: sheets.courseDismissals
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
            == AtThen(isPresenting: false, course: false, files: false, courseDismissals: 1))

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
        #expect(await Self.close(root, sheets).isPresenting)
        #expect(sheets.draft)
        sheets.draft = false
        try await waitUntil { root.presentedViewController == nil }

        sheets.conflict = true
        try await waitUntil { root.presentedViewController is UIAlertController }
        #expect(await Self.close(root, sheets).isPresenting)
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

        #expect(await !Self.close(root, sheets).isPresenting)
    }
}
#endif

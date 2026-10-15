#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// The status dot's popover gives the page's last sync on every page, not only on those built
/// from the school data, and leaves the row out for a page that read nothing.
@MainActor
@Suite(.serialized)
struct SyncStatusDotDetailsTests {
    private static let name = "Test source"

    /// The labels VoiceOver reaches in the popover a tap on `lastSynced`'s dot opens, once its
    /// source row is up.
    private static func popoverLabels(_ lastSynced: SyncStatusDot.LastSynced) async throws -> [String] {
        try await withAccessibilityAutomation {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 375, height: 667)
            let dot = SyncStatusDot(
                status: .ok, label: name, icon: "books.vertical.fill",
                text: SyncStatusDot.statusText(.ok), lastSynced: lastSynced
            )
            let host = UIHostingController(rootView: VStack { HStack { Spacer(); dot }; Spacer() })
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
            }

            let status = SyncStatusDot.statusText(.ok)
            try await waitUntil { accessibilityElement(labeled: status, in: host.view) != nil }
            _ = try #require(accessibilityElement(labeled: status, in: host.view)).accessibilityActivate()
            try await waitUntil(timeout: .seconds(10)) { host.presentedViewController != nil }
            let popover = try #require(host.presentedViewController?.view)
            try await waitUntil { accessibilityElement(labeled: name, in: popover) != nil }
            return labels(in: popover)
        }
    }

    private static func labels(in node: NSObject) -> [String] {
        var found = node.accessibilityLabel.map { [$0] } ?? []
        var children = node.accessibilityElements ?? []
        let count = node.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { node.accessibilityElement(at: $0) }
        }
        if let view = node as? UIView { children += view.subviews }
        for case let child as NSObject in children {
            found += labels(in: child)
        }
        return found
    }

    @Test("a page's own last sync shows its age")
    func aPageGivesItsOwnTime() async throws {
        let labels = try await Self.popoverLabels(.at(Date().addingTimeInterval(-5 * 60)))

        #expect(labels.contains(String(localized: "sync_status_last_synced")))
        #expect(labels.contains(String(format: String(localized: "sync_status_minutes_ago_short"), 5)))
    }

    @Test("a page whose data never arrived says so")
    func aPageThatNeverSyncedSaysSo() async throws {
        let labels = try await Self.popoverLabels(.at(nil))

        #expect(labels.contains(String(localized: "sync_status_last_synced")))
        #expect(labels.contains(String(localized: "sync_status_never_synced")))
    }

    @Test("a page showing nothing it read has no last sync")
    func aPageThatReadNothingHasNoRow() async throws {
        let labels = try await Self.popoverLabels(.hidden)

        #expect(labels.contains(Self.name))
        #expect(!labels.contains(String(localized: "sync_status_last_synced")))
    }
}
#endif

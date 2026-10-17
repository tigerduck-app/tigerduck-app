#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// A refresh of a course's Moodle page that fails while the page still shows what it had puts up a
/// short note (https://github.com/tigerduck-app/tigerduck-app/issues/432).
@MainActor
@Suite(.serialized)
struct MoodleRefreshFailureNoteTests {
    private struct Failure: Error {}

    /// A page reads the feed in its body, as the Moodle pages do, so the note sees each change.
    private struct Page: View {
        let feed: MoodleFeed<[Int]>

        var body: some View { Color.clear.moodleRefreshFailureNote(feed) }
    }

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleRefreshFailureNoteTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func feed(in root: URL) -> MoodleFeed<[Int]> {
        MoodleFeed(cacheName: "notes", ttl: 60, context: MoodleCacheContext(
            account: "B11399001",
            cache: DataCache(
                cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
            ),
            isCurrent: { true }
        ))
    }

    @Test("each failed fetch counts, and a success does not")
    func failuresCount() async {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = Self.feed(in: root)

        await feed.refresh { [1] }
        #expect(feed.failureCount == 0)
        await feed.refresh { throw Failure() }
        await feed.refresh { throw Failure() }
        #expect(feed.failureCount == 2)
        await feed.refresh { [2] }
        #expect(feed.failureCount == 2)
    }

    @Test("the note names a lost connection or Moodle's maintenance, and otherwise only says the refresh failed")
    func noteText() {
        let network = MoodleRefreshFailureNote.Note(
            text: String(localized: "error_network_unavailable"), symbol: "wifi.slash"
        )
        #expect(MoodleRefreshFailureNote.note(for: URLError(.notConnectedToInternet), hasContent: true, isShown: true) == network)
        #expect(MoodleRefreshFailureNote.note(
            for: MoodleWebserviceError.transientNetwork(underlying: "timed out"), hasContent: true, isShown: true
        ) == network)
        #expect(MoodleRefreshFailureNote.note(for: MoodleWebserviceError.siteMaintenance, hasContent: true, isShown: true)
            == .init(text: String(localized: "error_moodle_site_maintenance"), symbol: "exclamationmark.triangle"))
        #expect(MoodleRefreshFailureNote.note(for: Failure(), hasContent: true, isShown: true)
            == .init(text: String(localized: "course_moodle_refresh_failed"), symbol: "exclamationmark.triangle"))
    }

    /// With nothing kept, the page's own first-load error says it; a page under another one stays
    /// quiet, so VoiceOver does not announce a page the student cannot see.
    @Test("no note without a failure, without content on the page, or off screen")
    func noNote() {
        #expect(MoodleRefreshFailureNote.note(for: nil, hasContent: true, isShown: true) == nil)
        #expect(MoodleRefreshFailureNote.note(for: Failure(), hasContent: false, isShown: true) == nil)
        #expect(MoodleRefreshFailureNote.note(for: Failure(), hasContent: true, isShown: false) == nil)
    }

    @Test("a refresh that fails over cached content shows the note on the page")
    func noteShows() async throws {
        try await withAccessibilityAutomation {
            let root = Self.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let feed = Self.feed(in: root)
            await feed.refresh { [1] }
            let host = UIHostingController(rootView: Page(feed: feed))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()

            await feed.refresh { throw Failure() }

            let text = String(localized: "course_moodle_refresh_failed")
            try await waitUntil { accessibilityElement(labeled: text, in: host.view) != nil }
        }
    }
}
#endif

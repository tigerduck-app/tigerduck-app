#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MoodleRefreshFailureNoteTests {
    private struct Failure: Error {}

    @MainActor
    private final class Flag {
        var isOn = true
    }

    private struct Page: View {
        let feed: MoodleFeed<[Int]>
        let sleeper: ManualSleeper

        var body: some View {
            VStack {
                Text("failures \(feed.failureCount), items \(feed.value?.count ?? 0)")
                Color.clear
            }
            .moodleRefreshFailureNote(
                feed, hasContent: (feed.value?.count ?? 0) > 1, sleep: { await sleeper.sleep(for: $0) }
            )
        }
    }

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleRefreshFailureNoteTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func feed(in root: URL, isCurrent: @escaping () -> Bool = { true }) -> MoodleFeed<[Int]> {
        MoodleFeed(cacheName: "notes", ttl: 60, context: MoodleCacheContext(
            account: "B11399001",
            cache: DataCache(
                cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
            ),
            isCurrent: isCurrent
        ))
    }

    private static func model(_ sleeper: ManualSleeper) -> MoodleRefreshFailureNoteModel {
        MoodleRefreshFailureNoteModel(sleep: { await sleeper.sleep(for: $0) })
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

    @Test("a fetch that fails after the account changed does not count")
    func aDroppedFetchDoesNotCount() async {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let signedIn = Flag()
        let feed = Self.feed(in: root, isCurrent: { signedIn.isOn })

        await feed.refresh {
            await MainActor.run { signedIn.isOn = false }
            throw Failure()
        }
        #expect(feed.failureCount == 0)
    }

    @Test("a refresh that joins a running one counts its failure once")
    func aJoinedRefreshCountsOnce() async throws {
        let root = Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = Self.feed(in: root)
        let gate = ManualSleeper()

        let first = Task { await feed.refresh {
            await gate.sleep(for: .zero)
            throw Failure()
        } }
        try await gate.waitUntilArmed()
        let second = Task { await feed.refresh { throw Failure() } }
        await gate.fire()
        await first.value
        await second.value
        #expect(feed.failureCount == 1)
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

    @Test("no note without a failure, without content on the page, or off screen")
    func noNote() {
        #expect(MoodleRefreshFailureNote.note(for: nil, hasContent: true, isShown: true) == nil)
        #expect(MoodleRefreshFailureNote.note(for: Failure(), hasContent: false, isShown: true) == nil)
        #expect(MoodleRefreshFailureNote.note(for: Failure(), hasContent: true, isShown: false) == nil)
    }

    @Test("the note goes once its time is up, and a tap takes it down sooner")
    func theNoteGoes() async throws {
        let sleeper = ManualSleeper()
        let model = Self.model(sleeper)
        model.appeared()

        #expect(model.failed(Failure(), hasContent: true) != nil)
        try await sleeper.waitUntilArmed()
        #expect(await sleeper.requestedDurations == [MoodleRefreshFailureNoteModel.duration])
        #expect(model.note != nil)
        await sleeper.fire()
        try await waitUntil { model.note == nil }

        #expect(model.failed(Failure(), hasContent: true) != nil)
        model.close()
        #expect(model.note == nil)
        await sleeper.fire()
    }

    @Test("an earlier note's time does not take down a later one")
    func aLaterNoteWaitsForItself() async {
        let sleeper = ManualSleeper()
        let model = Self.model(sleeper)
        model.appeared()
        _ = model.failed(Failure(), hasContent: true)
        _ = model.failed(Failure(), hasContent: true)

        model.hide(ifStill: 1)
        #expect(model.note != nil)
        model.hide(ifStill: 2)
        #expect(model.note == nil)
        await sleeper.fire()
    }

    @Test("a page that leaves takes its note down and shows none until it is back")
    func offScreen() async {
        let sleeper = ManualSleeper()
        let model = Self.model(sleeper)
        model.appeared()
        _ = model.failed(Failure(), hasContent: true)

        model.disappeared()
        #expect(model.note == nil)
        #expect(model.failed(Failure(), hasContent: true) == nil)
        model.appeared()
        #expect(model.failed(Failure(), hasContent: true) != nil)
        await sleeper.fire()
    }

    @Test("on a page, a failure over its content shows the note and one over nothing it shows does not")
    func noteShowsOnlyOverContent() async throws {
        try await withAccessibilityAutomation {
            let root = Self.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let feed = Self.feed(in: root)
            let sleeper = ManualSleeper()
            let host = UIHostingController(rootView: Page(feed: feed, sleeper: sleeper))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            host.view.layoutIfNeeded()
            let text = String(localized: "course_moodle_refresh_failed")

            await feed.refresh { throw Failure() }
            try await waitUntil { accessibilityElement(labeled: "failures 1, items 0", in: host.view) != nil }
            await feed.refresh { [1] }
            try await waitUntil { accessibilityElement(labeled: "failures 1, items 1", in: host.view) != nil }
            #expect(accessibilityElement(labeled: text, in: host.view) == nil)

            await feed.refresh { throw Failure() }
            try await waitUntil { accessibilityElement(labeled: "failures 2, items 1", in: host.view) != nil }
            await feed.refresh { [1, 2] }
            try await waitUntil { accessibilityElement(labeled: "failures 2, items 2", in: host.view) != nil }
            #expect(accessibilityElement(labeled: text, in: host.view) == nil)

            await feed.refresh { throw Failure() }
            try await waitUntil { accessibilityElement(labeled: text, in: host.view) != nil }
            try await sleeper.waitUntilArmed()
            #expect(await sleeper.armedCount == 1)
            await sleeper.fire()
        }
    }
}
#endif

#if os(iOS)
import Foundation
import Testing
import UserNotifications
@testable import TigerDuck

final class RecordingNotificationCenter: MailNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var removed: [String] = []
    private(set) var removedAll = 0

    func add(_ request: UNNotificationRequest) async throws { lock.withLock { requests.append(request) } }
    func removeDelivered(withIdentifiers identifiers: [String]) { lock.withLock { removed += identifiers } }
    func removeAllMailNotifications() async { lock.withLock { removedAll += 1 } }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Records the inbox marker's value at the moment `notify` is awaited, to prove the checker
/// notifies before it persists the marker (fix round 1: a background-task expiration or process
/// kill during the awaited notify must never lose those notifications).
final class OrderingNotificationCenter: MailNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var wasCalled = false
    private(set) var markerWhenCalled: UInt32?
    private let prefs: any MailPreferences

    init(prefs: any MailPreferences) {
        self.prefs = prefs
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock {
            wasCalled = true
            markerWhenCalled = prefs.inboxNextUID
        }
    }
    func removeDelivered(withIdentifiers identifiers: [String]) {}
    func removeAllMailNotifications() async {}
}

/// Rejects the named notification identifiers the way `UNUserNotificationCenter.add` does when
/// the content is invalid or the notification service is unavailable, and accepts the rest.
final class RejectingNotificationCenter: MailNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var rejected: Set<String>
    private var _accepted: [String] = []
    var accepted: [String] { lock.withLock { _accepted } }

    init(rejecting: Set<String>) {
        rejected = rejecting
    }

    /// Lets a previously rejected identifier through, so a test can show the next check delivers it.
    func stopRejecting() {
        lock.withLock { rejected = [] }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try lock.withLock {
            guard !rejected.contains(request.identifier) else { throw MailClientError.protocolError("add refused") }
            _accepted.append(request.identifier)
        }
    }

    func removeDelivered(withIdentifiers identifiers: [String]) {}
    func removeAllMailNotifications() async {}
}

struct MailCheckerTests {
    struct Harness {
        let checker: MailChecker
        let prefs: InMemoryMailPreferences
        let fake: FakeMailClient
        let center: RecordingNotificationCenter
        let authFailures: Counter
    }

    static func harness(inbox: [FakeMailClient.Message], validity: UInt32? = 1, marker: UInt32? = nil) -> Harness {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = validity
        prefs.inboxNextUID = marker
        let fake = FakeMailClient(folders: ["INBOX": inbox])
        let center = RecordingNotificationCenter()
        let authFailures = Counter()
        let checker = MailChecker(
            prefs: prefs,
            notifier: MailNotifier(center: center),
            openSession: { fake },
            onAuthFailure: {
                prefs.authFailed = true
                await authFailures.increment()
            }
        )
        return Harness(checker: checker, prefs: prefs, fake: fake, center: center, authFailures: authFailures)
    }

    @Test func theFirstCheckOnlySetsTheBaseline() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 1), FakeMailClient.message(uid: 2)], marker: nil)
        #expect(await h.checker.check(trigger: .foreground) == .baselineReset)
        #expect(h.prefs.inboxNextUID == 3)
        #expect(h.center.requests.isEmpty)
    }

    @Test func aNewUIDValidityResetsTheBaselineQuietly() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 9)], validity: 77, marker: 1)
        #expect(await h.checker.check(trigger: .backgroundTask) == .baselineReset)
        #expect(h.prefs.inboxUIDValidity == 1)
        #expect(h.prefs.inboxNextUID == 10)
        #expect(h.center.requests.isEmpty)
    }

    @Test func newUnreadMailIsNotified() async throws {
        let h = Self.harness(inbox: [
            FakeMailClient.message(uid: 2, seen: true),
            FakeMailClient.message(uid: 3, from: "a@gmail.com", name: "Some\u{202E}one", subject: "Hi"),
            FakeMailClient.message(uid: 4, from: "office@mail.ntust.edu.tw", subject: ""),
        ], marker: 3)
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(2))
        #expect(h.prefs.inboxNextUID == 5)
        #expect(h.center.requests.map(\.identifier) == ["school-mail-1-3", "school-mail-1-4"])
        let first = try #require(h.center.requests.first?.content)
        #expect(first.title == "Someone")
        #expect(first.body == "Hi")
        #expect(first.threadIdentifier == "schoolMail")
        #expect(first.userInfo["kind"] as? String == "school_mail")
        #expect(first.userInfo["uid"] as? Int == 3)
        #expect(h.center.requests[1].content.title == "office@mail.ntust.edu.tw")
    }

    @Test func theMarkerIsNotAdvancedUntilNotifyHasCompleted() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 3
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 3)]])
        let center = OrderingNotificationCenter(prefs: prefs)
        let checker = MailChecker(
            prefs: prefs,
            notifier: MailNotifier(center: center),
            openSession: { fake },
            onAuthFailure: { prefs.authFailed = true }
        )
        #expect(await checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(center.wasCalled)
        #expect(center.markerWhenCalled == 3)
        #expect(prefs.inboxNextUID == 4)
    }

    @Test func seenOrDeletedArrivalsMoveTheMarkerWithoutNotifying() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 5, seen: true), FakeMailClient.message(uid: 6, deleted: true)], marker: 5)
        #expect(await h.checker.check(trigger: .backgroundTask) == .noNewMail)
        #expect(h.prefs.inboxNextUID == 7)
        #expect(h.center.requests.isEmpty)
    }

    @Test func theIMAPStarQuirkIsFilteredOut() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 5), FakeMailClient.message(uid: 6)], marker: 5)
        await h.fake.update { $0.extraSummaries = [SchoolMailTestDoubles.summary(uid: 4)] }
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(2))
        #expect(h.center.requests.map(\.identifier) == ["school-mail-1-5", "school-mail-1-6"])
    }

    @Test func moreThanFiveCollapseIntoOneNotification() async {
        let inbox = (UInt32(1)...6).map { FakeMailClient.message(uid: $0) }
        let h = Self.harness(inbox: inbox, marker: 1)
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(6))
        #expect(h.center.requests.map(\.identifier) == [MailNotifier.summaryIdentifier])
    }

    @Test func thePageTriggerAdvancesTheMarkerButNeverNotifies() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3)], marker: 3)
        #expect(await h.checker.check(trigger: .page) == .newMail(1))
        #expect(h.prefs.inboxNextUID == 4)
        #expect(h.center.requests.isEmpty)
    }

    @Test func aRejectedPasswordStopsFurtherChecks() async {
        let h = Self.harness(inbox: [], marker: 1)
        await h.fake.update { $0.statusError = .authenticationFailed }
        #expect(await h.checker.check(trigger: .backgroundTask) == .authFailed)
        #expect(await h.authFailures.value == 1)
        #expect(await h.checker.check(trigger: .backgroundTask) == .skippedAuthFailed)
    }

    @Test func networkFailuresLeaveTheMarkerAlone() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3)], marker: 3)
        await h.fake.update { $0.statusError = .unreachable }
        #expect(await h.checker.check(trigger: .backgroundTask) == .failed(.unreachable))
        #expect(h.prefs.inboxNextUID == 3)
    }

    @Test func onlyOneCheckRunsAtATime() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 1)], marker: nil)
        await h.fake.update { $0.holdStatus = true }
        let first = Task { await h.checker.check(trigger: .foreground) }
        while !(await h.fake.calls.contains("status INBOX")) { await Task.yield() }
        #expect(await h.checker.check(trigger: .backgroundTask) == .skippedBusy)
        await h.fake.releaseStatus()
        #expect(await first.value == .baselineReset)
    }

    @Test func disabledNotificationsSkipBackgroundChecksButNotThePage() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 1)], marker: nil)
        h.prefs.notificationsEnabled = false
        #expect(await h.checker.check(trigger: .backgroundTask) == .skippedDisabled)
        #expect(await h.checker.check(trigger: .page) == .baselineReset)
    }

    @Test func signedOutSkipsEverything() async {
        let h = Self.harness(inbox: [], marker: nil)
        h.prefs.studentID = nil
        #expect(await h.checker.check(trigger: .foreground) == .skippedSignedOut)
    }

    /// Alternating triggers, so "newest first" is actually pinned: with twelve identical records
    /// the ordering assertion held for any permutation, including the ring buffer keeping the ten
    /// *oldest*. Call 1 (no marker yet) is the baseline reset and calls 2–12 are `noNewMail`, so
    /// the surviving ten are calls 3–12: newest is call 12 (`page`), oldest kept is call 3
    /// (`foreground`), and the baseline reset must have been evicted.
    @Test func diagnosticsKeepTheTenNewest() async {
        let h = Self.harness(inbox: [], marker: nil)
        for index in 0..<12 {
            _ = await h.checker.check(trigger: index.isMultiple(of: 2) ? .foreground : .page)
        }
        #expect(h.prefs.diagnostics.count == 10)
        #expect(h.prefs.diagnostics.first?.trigger == "page")
        #expect(h.prefs.diagnostics.last?.trigger == "foreground")
        #expect(!h.prefs.diagnostics.contains { $0.result == MailCheckOutcome.baselineReset.diagnosticText })
        #expect(h.prefs.lastCheckAt != nil)
    }

    /// §8.5's contract is notify, *then* advance. A notification the system refuses is a failure
    /// the marker must respect too: advancing past it means that mail is never notified and never
    /// reconsidered by any trigger.
    @Test func aRefusedNotificationHoldsTheMarkerSoTheMailIsReconsidered() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 10
        let fake = FakeMailClient(folders: ["INBOX": [
            FakeMailClient.message(uid: 10), FakeMailClient.message(uid: 11), FakeMailClient.message(uid: 12),
        ]])
        let center = RejectingNotificationCenter(rejecting: ["school-mail-1-11"])
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { fake }, onAuthFailure: {})

        #expect(await checker.check(trigger: .backgroundTask) == .newMail(3))
        #expect(center.accepted == ["school-mail-1-10", "school-mail-1-12"])
        // Held at the refused UID, not advanced past it.
        #expect(prefs.inboxNextUID == 11)

        center.stopRejecting()
        #expect(await checker.check(trigger: .backgroundTask) == .newMail(2))
        #expect(center.accepted.suffix(2) == ["school-mail-1-11", "school-mail-1-12"])
        #expect(prefs.inboxNextUID == 13)
    }

    /// The collapsed "more than five" notification stands for every message in the batch, so if
    /// that single `add` is refused the marker may not move past any of them.
    @Test func aRefusedSummaryNotificationHoldsTheMarkerForTheWholeBatch() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 1
        let inbox = (UInt32(1)...6).map { FakeMailClient.message(uid: $0) }
        let center = RejectingNotificationCenter(rejecting: [MailNotifier.summaryIdentifier])
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { FakeMailClient(folders: ["INBOX": inbox]) }, onAuthFailure: {})

        #expect(await checker.check(trigger: .backgroundTask) == .newMail(6))
        #expect(center.accepted.isEmpty)
        #expect(prefs.inboxNextUID == 1)
    }

    @Test func notifierHelpers() async {
        let center = RecordingNotificationCenter()
        let notifier = MailNotifier(center: center)
        await notifier.notifyAuthFailure()
        notifier.removeNotification(uidValidity: 7, uid: 42)
        await notifier.removeAll()
        #expect(center.requests.map(\.identifier) == [MailNotifier.authFailureIdentifier])
        #expect(center.removed == ["school-mail-7-42"])
        #expect(center.removedAll == 1)
    }
}
#endif

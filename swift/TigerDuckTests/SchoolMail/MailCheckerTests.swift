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
    private let error: any Error
    var accepted: [String] { lock.withLock { _accepted } }

    /// `error` defaults to the shape of a refusal that might not happen again — a service that
    /// was unavailable for a moment. Pass a `UNError` to model one that certainly will.
    init(rejecting: Set<String>, error: any Error = MailClientError.protocolError("add refused")) {
        rejected = rejecting
        self.error = error
    }

    /// Lets a previously rejected identifier through, so a test can show the next check delivers it.
    func stopRejecting() {
        lock.withLock { rejected = [] }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try lock.withLock {
            guard !rejected.contains(request.identifier) else { throw error }
            _accepted.append(request.identifier)
        }
    }

    func removeDelivered(withIdentifiers identifiers: [String]) {}
    func removeAllMailNotifications() async {}
}

/// Signs a different student in at the exact moment a notification is posted — i.e. inside the
/// window between a check fetching its account's new mail and persisting that account's marker.
/// The notification itself is recorded so a test can say whether the previous student's mail was
/// announced on the new student's device.
final class AccountSwitchingNotificationCenter: MailNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private let prefs: any MailPreferences
    private let signedInDuringAdd: String?
    private var _requests: [UNNotificationRequest] = []
    var requests: [UNNotificationRequest] { lock.withLock { _requests } }

    /// `signedInDuringAdd` is the student ID that takes over partway through; `nil` models a
    /// plain sign-out landing there instead.
    init(prefs: any MailPreferences, signedInDuringAdd: String?) {
        self.prefs = prefs
        self.signedInDuringAdd = signedInDuringAdd
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _requests.append(request) }
        prefs.studentID = signedInDuringAdd
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

    static func harness(inbox: [FakeMailClient.Message], validity: UInt32? = 1, marker: UInt32? = nil,
                        cache: MailCache? = nil) -> Harness {
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
            },
            cache: cache
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
        // Title = "Email: " + subject, body = sender (design doc §8.6 has this reversed; the
        // ordering here is a deliberate override — see MailNotifier).
        let first = try #require(h.center.requests.first?.content)
        #expect(first.title == "Email: Hi")
        #expect(first.body == "Someone")
        #expect(first.threadIdentifier == "schoolMail")
        #expect(first.userInfo["kind"] as? String == "school_mail")
        #expect(first.userInfo["uid"] as? Int == 3)
        // No subject: the fallback text still lands inside the "Email: " prefix.
        #expect(h.center.requests[1].content.title == "Email: (No subject)")
        #expect(h.center.requests[1].content.body == "office@mail.ntust.edu.tw")
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

    /// Holding the marker is only right while there is something to wait for. When the system
    /// refuses because the student turned notification permission off, it will refuse the same
    /// way on every 60 s poll, so a held marker re-fetches and re-reports the same mail as new
    /// forever. A refusal that cannot change advances the marker like a delivered notification.
    @Test func aPermanentlyRefusedNotificationDoesNotWedgeTheMarker() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 10
        let fake = FakeMailClient(folders: ["INBOX": [
            FakeMailClient.message(uid: 10), FakeMailClient.message(uid: 11), FakeMailClient.message(uid: 12),
        ]])
        let center = RejectingNotificationCenter(rejecting: ["school-mail-1-11"],
                                                 error: UNError(.notificationsNotAllowed))
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { fake }, onAuthFailure: {})

        #expect(await checker.check(trigger: .backgroundTask) == .newMail(3))
        #expect(prefs.inboxNextUID == 13)
        // And the next poll finds nothing, instead of re-reporting UID 11 for ever.
        #expect(await checker.check(trigger: .backgroundTask) == .noNewMail)
        #expect(center.accepted == ["school-mail-1-10", "school-mail-1-12"])
    }

    /// The same for the collapsed batch: a permanent refusal of the one summary notification
    /// must not pin the marker to the bottom of the batch for ever.
    @Test func aPermanentlyRefusedSummaryDoesNotWedgeTheMarker() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 1
        let inbox = (UInt32(1)...6).map { FakeMailClient.message(uid: $0) }
        let center = RejectingNotificationCenter(rejecting: [MailNotifier.summaryIdentifier],
                                                 error: UNError(.notificationsNotAllowed))
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { FakeMailClient(folders: ["INBOX": inbox]) }, onAuthFailure: {})

        #expect(await checker.check(trigger: .backgroundTask) == .newMail(6))
        #expect(prefs.inboxNextUID == 7)
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

    // MARK: A check that outlives the account that started it

    /// A check in flight when the student signs out must not write its results back: the marker
    /// keys, the diagnostics ring and the notification centre are all shared with whatever
    /// account is signed in next (`AGENTS.md`: do not write previous-user data back after
    /// logout). It answers `.skippedSignedOut` — what it would have returned had the sign-out
    /// landed a moment earlier.
    @Test func aCheckWhoseAccountSignsOutMidFlightWritesNothing() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 5)], marker: 3)
        await h.fake.update { $0.holdStatus = true }
        let check = Task { await h.checker.check(trigger: .backgroundTask) }
        await h.fake.waitForArrival("status")
        h.prefs.studentID = nil
        await h.fake.releaseStatus()

        #expect(await check.value == .skippedSignedOut)
        #expect(h.prefs.inboxNextUID == 3)
        #expect(h.center.requests.isEmpty)
        #expect(h.prefs.diagnostics.isEmpty)
    }

    /// The same race one step later, and the one that actually reaches the notification centre:
    /// a different student signs in while this run's notifications are being posted. The marker
    /// it was about to advance now belongs to that student — advancing it would move them past
    /// mail they have never seen, which is mail they would then never be notified about.
    @Test func aCheckDoesNotAdvanceTheMarkerOfAnAccountThatSignedInMidRun() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 3
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)]])
        let center = AccountSwitchingNotificationCenter(prefs: prefs, signedInDuringAdd: "B29999999")
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { fake }, onAuthFailure: { prefs.authFailed = true })

        #expect(await checker.check(trigger: .backgroundTask) == .skippedSignedOut)
        #expect(prefs.inboxNextUID == 3)
        #expect(prefs.diagnostics.isEmpty)
    }

    /// `onAuthFailure` stops every background check for the account it is reported against, so a
    /// rejection of the *previous* student's saved password must never be recorded once someone
    /// else is signed in — it would lock the new account out of its own checks until it signed
    /// in again by hand.
    @Test func anAuthFailureIsNotReportedAgainstTheAccountThatSignedInAfterwards() async {
        let h = Self.harness(inbox: [], marker: 1)
        await h.fake.update {
            $0.statusError = .authenticationFailed
            $0.holdStatus = true
        }
        let check = Task { await h.checker.check(trigger: .backgroundTask) }
        await h.fake.waitForArrival("status")
        h.prefs.studentID = "B29999999"
        await h.fake.releaseStatus()

        #expect(await check.value == .skippedSignedOut)
        #expect(await h.authFailures.value == 0)
        #expect(h.prefs.authFailed == false)
    }

    @Test func resultsOnlyApplyToTheAccountThatStartedTheCheck() {
        #expect(MailChecker.resultsStillApply(startedAs: "B10000000", current: "B10000000"))
        #expect(!MailChecker.resultsStillApply(startedAs: "B10000000", current: nil))
        #expect(!MailChecker.resultsStillApply(startedAs: "B10000000", current: "B29999999"))
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

    // MARK: What the diagnostics screen shows

    /// The record keeps `diagnosticText` — unchanged, English, and what a pasted bug report is
    /// read against — and the screen renders `displayText(forStored:)`. These pin the map
    /// between the two rather than the English wording, which lives in the strings catalogue.
    @Test(arguments: [
        MailCheckOutcome.skippedBusy, .skippedSignedOut, .skippedDisabled, .skippedAuthFailed,
        .baselineReset, .noNewMail, .authFailed,
    ])
    func everyValuelessOutcomeRoundTripsThroughItsStoredText(outcome: MailCheckOutcome) {
        #expect(MailCheckOutcome.displayText(forStored: outcome.diagnosticText) == outcome.displayText)
        #expect(MailCheckOutcome.displayText(forStored: outcome.diagnosticText) != outcome.diagnosticText)
    }

    @Test func aCountAndAFailureKeepTheirValueThroughTheMap() {
        #expect(MailCheckOutcome.displayText(forStored: MailCheckOutcome.newMail(3).diagnosticText)
            == MailCheckOutcome.newMail(3).displayText)
        let failure = MailCheckOutcome.failed(.unreachable)
        // The underlying error is carried, not summarized: it is the only thing on this screen
        // a bug report can be diagnosed from.
        #expect(failure.diagnosticText.contains("unreachable"))
        #expect(MailCheckOutcome.displayText(forStored: failure.diagnosticText) == failure.displayText)
    }

    /// A record written by a build that knew a case this one does not is shown as it was
    /// written — never blank, never a key name.
    @Test func anUnrecognizedRecordIsShownAsWritten() {
        #expect(MailCheckOutcome.displayText(forStored: "something this build never wrote")
            == "something this build never wrote")
        #expect(MailCheckTrigger.displayText(forStored: "widget") == "widget")
    }

    // MARK: Body prefetch

    @Test func aNotifiedMailsBodyIsCachedForTheTap() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3, text: "hello")], marker: 3, cache: cache)
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 3)?.textBody == "hello")
    }

    @Test func aBurstPrefetchesOnlyTheNewestFive() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: (3...10).map { FakeMailClient.message(uid: $0) }, marker: 3, cache: cache)
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(8))
        let fetched = await h.fake.calls.filter { $0.hasPrefix("detail INBOX") }
        #expect(fetched == (6...10).reversed().map { "detail INBOX \($0)" })
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 5) == nil)
    }

    @Test func seenMailIsNotPrefetched() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3, seen: true), FakeMailClient.message(uid: 4)],
                             marker: 3, cache: cache)
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(await h.fake.calls.filter { $0.hasPrefix("detail") } == ["detail INBOX 4"])
    }

    /// The prefetch is a convenience on top of a check that has already done its job: a body
    /// that will not come down changes neither the outcome nor the marker.
    @Test func aFailedPrefetchLeavesTheCheckSucceeded() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)], marker: 3, cache: cache)
        await h.fake.update { $0.detailError = .protocolError("no body") }
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(2))
        #expect(h.prefs.inboxNextUID == 5)
        #expect(!h.prefs.authFailed)
        // A per-message error moves on to the next one...
        #expect(await h.fake.calls.filter { $0.hasPrefix("detail") } == ["detail INBOX 4", "detail INBOX 3"])
    }

    @Test func aDeadConnectionStopsThePrefetch() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)], marker: 3, cache: cache)
        await h.fake.update { $0.detailError = .unreachable }
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(2))
        // ...but one that says the connection is gone does not try the rest against it.
        #expect(await h.fake.calls.filter { $0.hasPrefix("detail") } == ["detail INBOX 4"])
    }

    @Test func nothingIsPrefetchedWithoutNewMail() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let baseline = Self.harness(inbox: [FakeMailClient.message(uid: 3)], marker: nil, cache: cache)
        #expect(await baseline.checker.check(trigger: .backgroundTask) == .baselineReset)
        #expect(await !baseline.fake.calls.contains { $0.hasPrefix("detail") })
        let quiet = Self.harness(inbox: [FakeMailClient.message(uid: 3)], marker: 4, cache: cache)
        #expect(await quiet.checker.check(trigger: .backgroundTask) == .noNewMail)
        #expect(await !quiet.fake.calls.contains { $0.hasPrefix("detail") })
    }

    /// The page trigger runs on the list's own connection, and the list fetches what it shows.
    @Test func thePageTriggerPrefetchesNothing() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3)], marker: 3, cache: cache)
        #expect(await h.checker.check(trigger: .page, using: h.fake) == .newMail(1))
        #expect(await !h.fake.calls.contains { $0.hasPrefix("detail") })
    }

    /// The prefetch runs after the marker is written, so a process death partway through it
    /// cannot make the next check notify the same mail again.
    @Test func theMarkerIsWrittenBeforeAnyBodyIsFetched() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3)], marker: 3, cache: cache)
        await h.fake.hold("detail")
        let check = Task { await h.checker.check(trigger: .backgroundTask) }
        await h.fake.waitForArrival("detail")
        #expect(h.prefs.inboxNextUID == 4)
        await h.fake.release("detail")
        #expect(await check.value == .newMail(1))
    }

    /// A body fetched for a student who has since signed out is previous-user data.
    @Test func aSignOutDuringThePrefetchWritesNoBody() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)], marker: 3, cache: cache)
        await h.fake.hold("detail")
        let check = Task { await h.checker.check(trigger: .backgroundTask) }
        await h.fake.waitForArrival("detail")
        h.prefs.studentID = nil
        await h.fake.release("detail")
        _ = await check.value
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 4) == nil)
        #expect(await h.fake.calls.filter { $0.hasPrefix("detail") } == ["detail INBOX 4"])
    }

    @Test(arguments: [MailClientError.unreachable, .certificateRejected, .authenticationFailed, .serverBusy])
    func connectionErrorsEndThePrefetch(error: MailClientError) {
        #expect(MailChecker.endsPrefetch(error))
    }

    @Test(arguments: [MailClientError.protocolError("x"), .folderChanged, .searchUnsupported])
    func messageErrorsDoNotEndThePrefetch(error: MailClientError) {
        #expect(!MailChecker.endsPrefetch(error))
    }

    @Test(arguments: [MailCheckTrigger.page, .foreground, .backgroundTask])
    func everyTriggerHasItsOwnDisplayText(trigger: MailCheckTrigger) {
        #expect(MailCheckTrigger.displayText(forStored: trigger.rawValue) == trigger.displayText)
        #expect(trigger.displayText != trigger.rawValue)
    }
}
#endif

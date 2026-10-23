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

    init(rejecting: Set<String>, error: any Error = MailClientError.protocolError("add refused")) {
        rejected = rejecting
        self.error = error
    }

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

final class AccountSwitchingNotificationCenter: MailNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private let prefs: any MailPreferences
    private let signedInDuringAdd: String?
    private var _requests: [UNNotificationRequest] = []
    private var _requestsAtRemoveAll: [Int] = []
    var requests: [UNNotificationRequest] { lock.withLock { _requests } }
    var requestsAtRemoveAll: [Int] { lock.withLock { _requestsAtRemoveAll } }

    init(prefs: any MailPreferences, signedInDuringAdd: String?) {
        self.prefs = prefs
        self.signedInDuringAdd = signedInDuringAdd
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { _requests.append(request) }
        prefs.studentID = signedInDuringAdd
    }

    func removeDelivered(withIdentifiers identifiers: [String]) {}
    func removeAllMailNotifications() async { lock.withLock { _requestsAtRemoveAll.append(_requests.count) } }
}

final class MarkerMovingNotificationCenter: MailNotificationCenter, @unchecked Sendable {
    private let prefs: any MailPreferences
    private let moveTo: UInt32
    private let validity: UInt32?

    init(prefs: any MailPreferences, moveTo: UInt32, validity: UInt32? = nil) {
        self.prefs = prefs
        self.moveTo = moveTo
        self.validity = validity
    }

    func add(_ request: UNNotificationRequest) async throws {
        if let validity { prefs.inboxUIDValidity = validity }
        prefs.inboxNextUID = moveTo
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
                        cache: MailCache? = nil, notificationsDenied: Bool = false) -> Harness {
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
            cache: cache,
            notificationsDenied: { notificationsDenied }
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
        #expect(first.title == "Hi")
        #expect(first.body == "Someone")
        #expect(first.threadIdentifier == "schoolMail")
        #expect(first.userInfo["kind"] as? String == "school_mail")
        #expect(first.userInfo["uid"] as? Int == 3)
        #expect(first.userInfo["uidValidity"] as? Int == 1)
        #expect(h.center.requests[1].content.title == String(localized: "school_mail_no_subject"))
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

    @Test func theOpenListMovesTheMarkerUpButNeverBack() async {
        let h = Self.harness(inbox: [], marker: 5)
        await h.checker.noteSeenByPage(MailboxStatusInfo(uidValidity: 1, uidNext: 8))
        #expect(h.prefs.inboxNextUID == 8)
        await h.checker.noteSeenByPage(MailboxStatusInfo(uidValidity: 1, uidNext: 6))
        #expect(h.prefs.inboxNextUID == 8)
        #expect(h.center.requests.isEmpty)
    }

    @Test func theOpenListAdoptsANewGeneration() async {
        let h = Self.harness(inbox: [], marker: 5)
        await h.checker.noteSeenByPage(MailboxStatusInfo(uidValidity: 2, uidNext: 3))
        #expect(h.prefs.inboxUIDValidity == 2)
        #expect(h.prefs.inboxNextUID == 3)
    }

    @Test func theOpenListWritesNothingSignedOut() async {
        let h = Self.harness(inbox: [], marker: 5)
        h.prefs.studentID = nil
        await h.checker.noteSeenByPage(MailboxStatusInfo(uidValidity: 1, uidNext: 8))
        #expect(h.prefs.inboxNextUID == 5)
    }

    @Test func aCheckKeepsTheMarkerTheOpenListMovedDuringItsNotify() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 3
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 3)]])
        let center = MarkerMovingNotificationCenter(prefs: prefs, moveTo: 9)
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { fake }, onAuthFailure: {})
        #expect(await checker.check(trigger: .foreground) == .newMail(1))
        #expect(prefs.inboxNextUID == 9)
    }

    @Test func aCheckLeavesTheMarkerOfAGenerationTheOpenListAdoptedDuringItsNotify() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 3
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)]])
        let center = MarkerMovingNotificationCenter(prefs: prefs, moveTo: 2, validity: 2)
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { fake }, onAuthFailure: {})
        #expect(await checker.check(trigger: .foreground) == .newMail(2))
        #expect(prefs.inboxUIDValidity == 2)
        #expect(prefs.inboxNextUID == 2)
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

    @Test func disabledNotificationsSkipEveryCheck() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 1)], marker: nil)
        h.prefs.notificationsEnabled = false
        #expect(await h.checker.check(trigger: .backgroundTask) == .skippedDisabled)
        #expect(await h.checker.check(trigger: .foreground) == .skippedDisabled)
    }

    @Test func deniedNotificationPermissionSkipsEveryCheckWithoutSigningIn() async {
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 1)], marker: nil, notificationsDenied: true)
        #expect(await h.checker.check(trigger: .backgroundTask) == .skippedDisabled)
        #expect(await h.checker.check(trigger: .foreground) == .skippedDisabled)
        #expect(await h.fake.calls.isEmpty)
        #expect(h.prefs.lastCheckAt == nil)
        #expect(h.prefs.inboxNextUID == nil)
    }

    @Test func aSignOutWhileThePermissionIsReadWritesNothing() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 1)]])
        let checker = MailChecker(
            prefs: prefs, notifier: MailNotifier(center: RecordingNotificationCenter()),
            openSession: { fake }, onAuthFailure: {},
            notificationsDenied: {
                prefs.studentID = nil
                return false
            }
        )
        #expect(await checker.check(trigger: .foreground) == .skippedSignedOut)
        #expect(prefs.lastCheckAt == nil)
        #expect(await fake.calls.isEmpty)
    }

    @Test func signedOutSkipsEverything() async {
        let h = Self.harness(inbox: [], marker: nil)
        h.prefs.studentID = nil
        #expect(await h.checker.check(trigger: .foreground) == .skippedSignedOut)
    }

    @Test func diagnosticsKeepTheTenNewest() async {
        let h = Self.harness(inbox: [], marker: nil)
        for index in 0..<12 {
            _ = await h.checker.check(trigger: index.isMultiple(of: 2) ? .foreground : .backgroundTask)
        }
        #expect(h.prefs.diagnostics.count == 10)
        #expect(h.prefs.diagnostics.first?.trigger == "backgroundTask")
        #expect(h.prefs.diagnostics.last?.trigger == "foreground")
        #expect(!h.prefs.diagnostics.contains { $0.result == MailCheckOutcome.baselineReset.diagnosticText })
        #expect(h.prefs.lastCheckAt != nil)
    }

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
        #expect(prefs.inboxNextUID == 11)

        center.stopRejecting()
        #expect(await checker.check(trigger: .backgroundTask) == .newMail(2))
        #expect(center.accepted.suffix(2) == ["school-mail-1-11", "school-mail-1-12"])
        #expect(prefs.inboxNextUID == 13)
    }

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
        #expect(await checker.check(trigger: .backgroundTask) == .noNewMail)
        #expect(center.accepted == ["school-mail-1-10", "school-mail-1-12"])
    }

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

    @Test func aRunWhoseAccountSignsOutWhileNotifyingTakesItsNotificationsBack() async {
        let prefs = InMemoryMailPreferences()
        prefs.studentID = "B10000000"
        prefs.inboxUIDValidity = 1
        prefs.inboxNextUID = 3
        let fake = FakeMailClient(folders: ["INBOX": [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)]])
        let center = AccountSwitchingNotificationCenter(prefs: prefs, signedInDuringAdd: nil)
        let checker = MailChecker(prefs: prefs, notifier: MailNotifier(center: center),
                                  openSession: { fake }, onAuthFailure: { prefs.authFailed = true })

        #expect(await checker.check(trigger: .backgroundTask) == .skippedSignedOut)
        #expect(center.requests.count == 2)
        #expect(center.requestsAtRemoveAll == [2])
    }

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
        #expect(failure.diagnosticText.contains("unreachable"))
        #expect(MailCheckOutcome.displayText(forStored: failure.diagnosticText) == failure.displayText)
    }

    @Test func anUnrecognizedRecordIsShownAsWritten() {
        #expect(MailCheckOutcome.displayText(forStored: "something this build never wrote")
            == "something this build never wrote")
        #expect(MailCheckTrigger.displayText(forStored: "widget") == "widget")
    }

    @Test func aNotifiedMailsBodyIsCachedForTheTap() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3, text: "hello")], marker: 3, cache: cache)
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(1))
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 3)?.textBody == "hello")
        #expect(await h.fake.detailsWithoutImages == [3])
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

    @Test func aFailedPrefetchLeavesTheCheckSucceeded() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)], marker: 3, cache: cache)
        await h.fake.update { $0.detailError = .protocolError("no body") }
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(2))
        #expect(h.prefs.inboxNextUID == 5)
        #expect(!h.prefs.authFailed)
        #expect(await h.fake.calls.filter { $0.hasPrefix("detail") } == ["detail INBOX 4", "detail INBOX 3"])
    }

    @Test func aDeadConnectionStopsThePrefetch() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3), FakeMailClient.message(uid: 4)], marker: 3, cache: cache)
        await h.fake.update { $0.detailError = .unreachable }
        #expect(await h.checker.check(trigger: .backgroundTask) == .newMail(2))
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

    @Test func aBodyOnTheWireWhenTheCacheIsWipedIsNotSaved() async {
        let cache = SchoolMailTestDoubles.temporaryCache()
        let h = Self.harness(inbox: [FakeMailClient.message(uid: 3)], marker: 3, cache: cache)
        await h.fake.hold("detail")
        let check = Task { await h.checker.check(trigger: .backgroundTask) }
        await h.fake.waitForArrival("detail")
        cache.clearAll()
        await h.fake.release("detail")

        #expect(await check.value == .newMail(1))
        #expect(cache.loadDetail(folder: "INBOX", uidValidity: 1, uid: 3) == nil)
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

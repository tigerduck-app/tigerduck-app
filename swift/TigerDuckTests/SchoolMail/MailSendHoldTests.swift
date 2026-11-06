#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct MailSendHoldTests {
    private typealias Compose = MailComposeViewModelTests

    @MainActor
    final class BackgroundTasks {
        var begun = 0
        var ended = 0
        var expired = false
        var announced = 0
    }

    struct Rig {
        let hold: MailSendHold
        let sleeper: ManualSleeper
        let events: NotificationCenter
        let tasks: BackgroundTasks
    }

    static func rig() -> Rig {
        let sleeper = ManualSleeper()
        let events = NotificationCenter()
        let tasks = BackgroundTasks()
        let hold = MailSendHold(
            sleep: { await sleeper.sleep(for: $0) },
            beginBackgroundTask: {
                tasks.begun += 1
                return MailSendHold.BackgroundGrant(isExpired: { tasks.expired }, end: { tasks.ended += 1 })
            },
            announce: { tasks.announced += 1 },
            events: events
        )
        return Rig(hold: hold, sleeper: sleeper, events: events, tasks: tasks)
    }

    static func written(_ fake: FakeMailClient, to: String = "a@mail.ntust.edu.tw",
                        context: MailComposeContext = MailComposeContext(mode: .new), account: AccountSession? = nil,
                        session: MailPageSession? = nil, events: MailboxEvents? = nil) async -> MailComposeViewModel {
        let model = MailComposeViewModel(
            context: context,
            session: session ?? MailPageSession(idleClose: .milliseconds(10), open: { fake }, onAuthFailure: { _ in }, account: account),
            sender: Compose.me, folderRoles: [.inbox: "INBOX", .sent: Compose.sent, .drafts: Compose.drafts],
            events: events, prefs: InMemoryMailPreferences(), cache: SchoolMailTestDoubles.temporaryCache(), sleep: { _ in }
        )
        await model.prepare()
        model.to = to
        model.subject = "期末報告"
        model.body = "老師好，附上報告。"
        model.addAttachment(filename: "報告.pdf", mimeType: "application/pdf", data: Data("%PDF".utf8))
        return model
    }

    @Test func aHeldMailGoesAfterFiveSecondsInsideABackgroundTask() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let model = await Self.written(fake)
        #expect(model.readyToSend())

        #expect(rig.hold.hold(model))
        #expect(rig.hold.held?.model === model)
        #expect(rig.tasks.announced == 1)
        try await rig.sleeper.waitUntilArmed()
        #expect(await rig.sleeper.requestedDurations == [.seconds(5)])
        #expect(await fake.sent.isEmpty)

        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }
        #expect(await fake.sent.map(\.to) == [["a@mail.ntust.edu.tw"]])
        #expect(model.didFinish)
        #expect(rig.hold.held == nil)
        #expect(rig.hold.takeReopened() == nil)
        #expect(rig.tasks.begun == 1)
        #expect(rig.tasks.ended == 1)
    }

    @Test func undoWithinTheHoldReopensEverythingAndSendsNothing() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let model = await Self.written(fake)
        rig.hold.hold(model)
        try await rig.sleeper.waitUntilArmed()

        rig.hold.undo()
        #expect(rig.hold.held == nil)
        #expect(rig.hold.takeReopened() === model)
        #expect(rig.hold.takeReopened() == nil)
        #expect(model.to == "a@mail.ntust.edu.tw")
        #expect(model.subject == "期末報告")
        #expect(model.body == "老師好，附上報告。")
        #expect(model.attachments.map(\.filename) == ["報告.pdf"])
        #expect(model.hasChanges)
        #expect(!model.didFinish)

        let next = await Self.written(fake, to: "b@mail.ntust.edu.tw")
        rig.hold.hold(next)
        try await rig.sleeper.waitUntilArmed(atLeast: 2)
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }
        #expect(await fake.sent.map(\.to) == [["b@mail.ntust.edu.tw"]])
        #expect(rig.tasks.begun == 1)
    }

    @Test func aSignOutDuringTheHoldSendsNothing() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let account = AccountSession()
        let signedOut = await Self.written(fake, account: account)
        rig.hold.hold(signedOut)
        try await rig.sleeper.waitUntilArmed()
        account.endSignIn()
        rig.events.post(name: MailAccountManager.didSignOut, object: nil)
        #expect(rig.hold.held == nil)

        let switched = AccountSession()
        let late = await Self.written(fake, account: switched)
        rig.hold.hold(late)
        try await rig.sleeper.waitUntilArmed(atLeast: 2)
        switched.endSignIn()
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }

        #expect(await fake.sent.isEmpty)
        #expect(await !fake.calls.contains { $0.hasPrefix("append") })
        #expect(late.shouldClose)
        #expect(!signedOut.didFinish)
        #expect(rig.hold.takeReopened() == nil)
    }

    @Test func goingToTheBackgroundSendsTheHeldMailAtOnceAndOnce() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let model = await Self.written(fake)
        rig.hold.hold(model)
        try await rig.sleeper.waitUntilArmed()

        rig.events.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(rig.hold.held == nil)
        #expect(rig.tasks.begun == 1)
        try await waitUntil { rig.hold.deliveries == 1 }
        #expect(model.didFinish)
        rig.events.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        await rig.sleeper.fire()

        let next = await Self.written(fake, to: "b@mail.ntust.edu.tw")
        rig.hold.hold(next)
        try await rig.sleeper.waitUntilArmed(atLeast: 2)
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 2 }
        #expect(await fake.sent.map(\.to) == [["a@mail.ntust.edu.tw"], ["b@mail.ntust.edu.tw"]])
        #expect(rig.tasks.begun == 2)
        #expect(rig.tasks.ended == 2)
    }

    @Test func aSendThatFailsAfterTheHoldReopensWithTheError() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        await fake.update { $0.sendError = .unreachable }
        let model = await Self.written(fake)
        rig.hold.hold(model)
        try await rig.sleeper.waitUntilArmed()
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }

        #expect(rig.hold.takeReopened() === model)
        #expect(model.error == String(localized: "school_mail_send_failed") + "\n"
                + MailAccountManager.LoginError(MailClientError.unreachable).message)
        #expect(model.errorNeedsAcknowledging)
        #expect(!model.didFinish)
        #expect(model.subject == "期末報告")
        #expect(model.attachments.map(\.filename) == ["報告.pdf"])
    }

    @Test func anUnconfirmedSendIsNeverSentAgainOnItsOwn() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        await fake.update { $0.sendError = .sendUnconfirmed }
        let model = await Self.written(fake)
        rig.hold.hold(model)
        try await rig.sleeper.waitUntilArmed()
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }

        #expect(rig.hold.takeReopened() === model)
        #expect(model.error == String(localized: "school_mail_send_unconfirmed"))
        #expect(await fake.calls.filter { $0 == "send" }.count == 1)
        #expect(await rig.sleeper.armedCount == 1)
    }

    @Test func aSecondTapOnSendHoldsTheMailOnce() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let model = await Self.written(fake)
        #expect(rig.hold.hold(model))
        #expect(rig.hold.hold(model))
        try await rig.sleeper.waitUntilArmed()
        #expect(await rig.sleeper.armedCount == 1)
        #expect(rig.tasks.announced == 1)

        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }
        #expect(!rig.hold.hold(model))
        #expect(rig.hold.held == nil)
        #expect(await fake.sent.count == 1)
    }

    @Test func holdingAnotherMailSendsTheFirstAtOnce() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let first = await Self.written(fake)
        let second = await Self.written(fake, to: "b@mail.ntust.edu.tw")
        rig.hold.hold(first)
        try await rig.sleeper.waitUntilArmed()

        rig.hold.hold(second)
        #expect(rig.hold.held?.model === second)
        try await waitUntil { rig.hold.deliveries == 1 }
        #expect(await fake.sent.map(\.to) == [["a@mail.ntust.edu.tw"]])

        try await rig.sleeper.waitUntilArmed(atLeast: 2)
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 2 }
        #expect(await fake.sent.map(\.to) == [["a@mail.ntust.edu.tw"], ["b@mail.ntust.edu.tw"]])
    }

    @Test func twoFailedSendsInARowBothComeBackInOrder() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        await fake.update { $0.sendError = .unreachable }
        let first = await Self.written(fake)
        let second = await Self.written(fake, to: "b@mail.ntust.edu.tw")
        rig.hold.hold(first)
        rig.hold.hold(second)
        try await rig.sleeper.waitUntilArmed(atLeast: 2)
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 2 }

        #expect(rig.hold.takeReopened() === first)
        #expect(rig.hold.takeReopened() === second)
        #expect(rig.hold.takeReopened() == nil)
    }

    @Test func aDraftOpenedAgainDuringTheHoldGoesOnce() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let draft = MailComposeContext(mode: .draft, folder: Compose.drafts, uid: 7)
        let held = await Self.written(fake, context: draft)
        let reopened = await Self.written(fake, context: draft)
        let late = await Self.written(fake, context: draft)
        rig.hold.hold(held)
        try await rig.sleeper.waitUntilArmed()

        #expect(rig.hold.hold(reopened))
        #expect(rig.hold.held == nil)
        #expect(rig.hold.hold(late))
        #expect(rig.hold.held == nil)
        try await waitUntil { rig.hold.deliveries == 1 }
        #expect(await fake.sent.count == 1)
        #expect(held.didFinish)

        let other = await Self.written(fake, context: MailComposeContext(mode: .draft, folder: Compose.drafts, uid: 8))
        #expect(rig.hold.hold(other))
        #expect(rig.hold.held?.model === other)
        rig.hold.undo()
    }

    @Test func aGrantThatRunsOutBeforeTheSendStartsSendsNothingAndReopens() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        let model = await Self.written(fake)
        rig.hold.hold(model)
        try await rig.sleeper.waitUntilArmed()
        rig.tasks.expired = true
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }

        #expect(await fake.sent.isEmpty)
        #expect(rig.hold.takeReopened() === model)
        #expect(model.error == String(localized: "school_mail_send_failed") + "\n" + MailAccountManager.LoginError.generic.message)
        #expect(rig.tasks.ended == 1)
    }

    @Test func aMailFromAComposerOwnSessionIsSentAndReportedAndItsConnectionClosesAfter() async throws {
        let rig = Self.rig()
        let fake = Compose.fake()
        await fake.update { $0.appendError = .unreachable }
        let events = MailboxEvents()
        var notices: [String] = []
        events.observe { if case let .sentCopyNotice(text) = $0 { notices.append(text) } }
        let timer = ManualSleeper()
        let session = MailPageSession(idleClose: .milliseconds(10), closesWhenIdle: true, open: { fake }, onAuthFailure: { _ in },
                                      sleep: { await timer.sleep(for: $0) })
        let model = await Self.written(fake, session: session, events: events)
        rig.hold.hold(model)
        try await rig.sleeper.waitUntilArmed()
        await rig.sleeper.fire()
        try await waitUntil { rig.hold.deliveries == 1 }

        #expect(await fake.sent.map(\.to) == [["a@mail.ntust.edu.tw"]])
        #expect(notices.count == 1)
        try await timer.waitUntilArmed()
        await timer.fire()
        await fake.waitForArrival("logout")
    }
}
#endif

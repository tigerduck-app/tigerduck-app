import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct TLSPinMismatchQueueTests {
    typealias F = TLSPinFixtures

    nonisolated static func mismatch(_ setID: String = "ntust") -> TLSPinMismatch {
        TLSPinMismatch(
            setID: setID, host: "moodle2.ntust.edu.tw", domains: ["ntust.edu.tw"], issuerOrganization: "TAIWAN-CA",
            certificates: [], acceptedSPKIs: [F.ntustLeafSPKI, F.secureSSLCASPKI]
        )
    }

    final class Clock {
        var now = F.now
    }

    private func queue(
        engine: TLSPinEngine = F.engine(), defaults: UserDefaults = F.defaults(), clock: Clock = Clock(),
        afterContinue: @escaping @MainActor () -> Void = {}
    ) -> TLSPinMismatchQueue {
        let queue = TLSPinMismatchQueue(engine: engine, defaults: defaults, clock: { clock.now }, afterContinue: afterContinue)
        queue.isForeground = true
        return queue
    }

    @Test("A set is asked about at most once per launch")
    func oncePerSetPerLaunch() {
        let queue = queue()
        queue.report(Self.mismatch())
        #expect(queue.prompt == Self.mismatch())
        queue.continue()
        queue.report(Self.mismatch())
        #expect(queue.prompt == nil)
        queue.report(Self.mismatch("library"))
        #expect(queue.prompt?.setID == "library")
    }

    @Test("One prompt at a time")
    func onePromptAtATime() {
        let queue = queue()
        queue.report(Self.mismatch())
        queue.report(Self.mismatch("library"))
        #expect(queue.prompt?.setID == "ntust")
        queue.cancel()
        #expect(queue.prompt == nil)
    }

    @Test("After a Cancel the set is not asked about for an hour, across launches")
    func aCancelStartsAQuietHour() {
        let defaults = F.defaults()
        let clock = Clock()
        let first = queue(defaults: defaults, clock: clock)
        first.report(Self.mismatch())
        first.cancel()

        clock.now = F.now.addingTimeInterval(59 * 60)
        let relaunched = queue(defaults: defaults, clock: clock)
        relaunched.report(Self.mismatch())
        #expect(relaunched.prompt == nil)

        clock.now = F.now.addingTimeInterval(61 * 60)
        relaunched.report(Self.mismatch())
        #expect(relaunched.prompt?.setID == "ntust")
    }

    @Test("A mismatch from the background waits for the foreground")
    func aBackgroundFailureQueuesThePrompt() {
        let queue = queue()
        queue.isForeground = false
        queue.report(Self.mismatch())
        #expect(queue.prompt == nil)
        queue.isForeground = true
        #expect(queue.prompt == Self.mismatch())
    }

    @Test("A held mismatch the pins now let through is dropped")
    func aStalePromptIsDropped() {
        let engine = F.engine()
        engine.acceptDocument(F.envelope(F.payload(serial: 100, sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])])))
        var mismatch = Self.mismatch()
        mismatch.chainSPKIs = [F.ntustLeafSPKI, F.secureSSLCASPKI, F.globalRootSPKI]
        let queue = queue(engine: engine)
        queue.isForeground = false
        queue.report(mismatch)
        engine.acceptDocument(F.envelope(F.payload(serial: 101)))
        queue.isForeground = true
        #expect(queue.prompt == nil)
        queue.report(Self.mismatch("library"))
        #expect(queue.prompt?.setID == "library")
    }

    @Test("A prompt open as the app leaves is asked again on return, unless the pins now allow it")
    func leavingTheForegroundHoldsThePrompt() {
        let engine = F.engine()
        engine.acceptDocument(F.envelope(F.payload(serial: 100, sets: [F.set("ntust", domain: "ntust.edu.tw", pins: [F.unknownSPKI])])))
        var mismatch = Self.mismatch()
        mismatch.chainSPKIs = [F.ntustLeafSPKI, F.secureSSLCASPKI, F.globalRootSPKI]
        let queue = queue(engine: engine)
        queue.report(mismatch)
        queue.isForeground = false
        #expect(queue.prompt == nil)
        queue.isForeground = true
        #expect(queue.prompt == mismatch)

        queue.isForeground = false
        engine.acceptDocument(F.envelope(F.payload(serial: 101)))
        queue.isForeground = true
        #expect(queue.prompt == nil)
    }

    @Test("Continue stores the leaf and intermediates and refreshes")
    func continueStoresTheAcceptance() throws {
        let engine = F.engine()
        var refreshed = 0
        let queue = queue(engine: engine, afterContinue: { refreshed += 1 })
        queue.report(Self.mismatch())
        queue.continue()
        #expect(queue.prompt == nil)
        #expect(refreshed == 1)
        let stored = try #require(engine.acceptances.first)
        #expect(stored.setID == "ntust")
        #expect(stored.spkis == [F.ntustLeafSPKI, F.secureSSLCASPKI])
        guard case .pinned(let set) = engine.policy(forHost: "moodle2.ntust.edu.tw") else {
            Issue.record("moodle2.ntust.edu.tw is not pinned")
            return
        }
        #expect(set.pins.isSuperset(of: stored.spkis))
    }

    @Test("Cancel stores nothing")
    func cancelStoresNothing() {
        let engine = F.engine()
        var refreshed = 0
        let queue = queue(engine: engine, afterContinue: { refreshed += 1 })
        queue.report(Self.mismatch())
        queue.cancel()
        #expect(engine.acceptances.isEmpty)
        #expect(refreshed == 0)
    }

    #if os(iOS)
    @Test("A School Mail refusal in the background reaches the queue with no UI", .timeLimit(.minutes(1)))
    func aMailRefusalQueuesAPrompt() async {
        let engine = F.engine(now: TLSPinEnforcementTests.date)
        engine.acceptDocument(TLSPinEnforcementTests.movedPins(promptRoots: [F.globalRootSPKI]))
        let queue = queue(engine: engine)
        queue.isForeground = false
        let (reported, signal) = AsyncStream<Void>.makeStream()
        engine.install(refresh: nil, report: { mismatch in
            Task { @MainActor in
                queue.report(mismatch)
                signal.yield()
            }
        })
        #expect(!MailTLSVerifier.verify(
            derChain: TLSPinningDelegateTests.wwwChain, host: "mail.ntust.edu.tw",
            now: TLSPinEnforcementTests.date, engine: engine
        ))
        var iterator = reported.makeAsyncIterator()
        await iterator.next()
        #expect(queue.prompt == nil)
        queue.isForeground = true
        #expect(queue.prompt?.host == "mail.ntust.edu.tw")
    }
    #endif
}

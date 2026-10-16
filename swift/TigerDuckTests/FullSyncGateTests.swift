// `FullSyncGate`, which runs one full sync at a time. A sync trigger push that arrived during a
// pull used to be turned away, and the change it announced stayed unfetched in the background.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct FullSyncGateTests {
    /// A full sync whose first run parks until `release()` and syncs; later runs fail. Records when
    /// each run starts and ends, and what the callers note.
    @MainActor
    private final class Pull {
        private(set) var events: [String] = []
        private var runs = 0
        private var parked: CheckedContinuation<Void, Never>?

        var isParked: Bool { parked != nil }

        func run() async -> FullSyncOutcome {
            runs += 1
            let run = runs
            events.append("start \(run)")
            if run == 1 { await withCheckedContinuation { parked = $0 } }
            events.append("end \(run)")
            return run == 1 ? .synced : .failed
        }

        func note(_ event: String) { events.append(event) }

        func release() {
            parked?.resume()
            parked = nil
        }
    }

    private static func call(
        _ gate: FullSyncGate, _ pull: Pull, followUp: Bool, mayFollow: Bool = true, note: String
    ) -> Task<FullSyncOutcome, Never> {
        Task {
            let outcome = await gate.run(followUp: followUp, mayFollow: { mayFollow }) { await pull.run() }
            pull.note(note)
            return outcome
        }
    }

    @Test("A trigger during a pull waits for one more pull that starts after it, and gets that one's outcome")
    func triggerDuringAPullGetsAFollowUp() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }
        let trigger = Self.call(gate, pull, followUp: true, note: "trigger returned")
        try await waitUntil { gate.queuedFollowUps == 1 }

        pull.release()
        #expect(await trigger.value == .failed)
        #expect(await first.value == .synced)

        #expect(pull.events.prefix(4) == ["start 1", "end 1", "start 2", "end 2"])
        #expect(pull.events.dropFirst(4).contains("trigger returned"))
        #expect(!gate.isRunning)
    }

    @Test("Triggers during one pull share one follow-up")
    func triggersShareOneFollowUp() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }
        let triggers = [
            Self.call(gate, pull, followUp: true, note: "trigger returned"),
            Self.call(gate, pull, followUp: true, note: "trigger returned"),
        ]
        try await waitUntil { gate.queuedFollowUps == 2 }

        pull.release()
        for trigger in triggers { _ = await trigger.value }
        _ = await first.value

        #expect(pull.events.filter { $0.hasPrefix("start") } == ["start 1", "start 2"])
    }

    @Test("A pull to refresh during a pull is turned away at once")
    func plainCallDuringAPullIsTurnedAway() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }

        #expect(await Self.call(gate, pull, followUp: false, note: "second returned").value == .skipped)
        #expect(pull.events == ["start 1", "second returned"])

        pull.release()
        _ = await first.value
        #expect(pull.events.filter { $0.hasPrefix("start") } == ["start 1"])
    }

    @Test("No follow-up runs once sync is off, and the trigger still returns")
    func noFollowUpOnceSyncIsOff() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: false, mayFollow: false, note: "first returned")
        try await waitUntil { pull.isParked }
        let trigger = Self.call(gate, pull, followUp: true, note: "trigger returned")
        try await waitUntil { gate.queuedFollowUps == 1 }

        pull.release()
        #expect(await trigger.value == .skipped)
        _ = await first.value

        #expect(pull.events.filter { $0.hasPrefix("start") } == ["start 1"])
        #expect(pull.events.contains("trigger returned"))
    }

    @Test("A sync cancelled at a sync trigger's time limit counts as no result, and a network failure as a failure")
    func cancellationIsNoResult() {
        #expect(AppState.isCancellation(CancellationError()))
        #expect(AppState.isCancellation(URLError(.cancelled)))
        #expect(!AppState.isCancellation(URLError(.timedOut)))
        #expect(!AppState.isCancellation(PushAPIError.httpStatus(503, body: "")))
    }
}

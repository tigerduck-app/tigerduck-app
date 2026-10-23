import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct FullSyncGateTests {
    @MainActor
    private final class Pull {
        private(set) var events: [String] = []
        private var runs = 0
        private var parked: CheckedContinuation<Void, Never>?
        private let parking: Set<Int>

        init(parking: Set<Int> = [1]) {
            self.parking = parking
        }

        var isParked: Bool { parked != nil }

        func run() async -> FullSyncOutcome {
            runs += 1
            let run = runs
            events.append("start \(run)")
            if parking.contains(run) {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { parked = $0 }
                } onCancel: {
                    Task { @MainActor in self.release() }
                }
            }
            events.append(Task.isCancelled ? "end \(run), cancelled" : "end \(run)")
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

        #expect(pull.events == ["start 1", "end 1", "first returned", "start 2", "end 2", "trigger returned"])
        #expect(!gate.isRunning)
    }

    @Test("A follow-up is not cancelled with the call whose pull came before it")
    func aFollowUpOutlivesTheCallBeforeIt() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: true, note: "first returned")
        try await waitUntil { pull.isParked }
        let trigger = Self.call(gate, pull, followUp: true, note: "trigger returned")
        try await waitUntil { gate.queuedFollowUps == 1 }

        first.cancel()
        #expect(await trigger.value == .failed)

        #expect(pull.events.filter { $0.hasPrefix("start") || $0.hasPrefix("end") }
            == ["start 1", "end 1, cancelled", "start 2", "end 2"])
    }

    @Test("A trigger that gives up while it waits returns at once, and no follow-up runs for it")
    func aWaiterThatGivesUpGetsNoFollowUp() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }
        let trigger = Self.call(gate, pull, followUp: true, note: "trigger returned")
        try await waitUntil { gate.queuedFollowUps == 1 }

        trigger.cancel()
        try await waitUntil(timeout: .seconds(5)) { pull.events.contains("trigger returned") }
        #expect(gate.queuedFollowUps == 0)
        #expect(pull.isParked)

        pull.release()
        #expect(await trigger.value == .skipped)
        #expect(await first.value == .synced)
        #expect(pull.events.filter { $0.hasPrefix("start") } == ["start 1"])
    }

    @Test("A follow-up is cancelled once every call waiting for it gives up")
    func aFollowUpNobodyWaitsForIsCancelled() async throws {
        let gate = FullSyncGate()
        let pull = Pull(parking: [1, 2])
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }
        let trigger = Self.call(gate, pull, followUp: true, note: "trigger returned")
        try await waitUntil { gate.queuedFollowUps == 1 }
        pull.release()
        try await waitUntil { pull.events.contains("start 2") && pull.isParked }

        trigger.cancel()
        try await waitUntil(timeout: .seconds(5)) { pull.events.contains("end 2, cancelled") }
        pull.release()

        #expect(await trigger.value == .skipped)
        #expect(await first.value == .synced)
        try await waitUntil(timeout: .seconds(5)) { !gate.isRunning }
    }

    @Test("A follow-up goes on while a call still waits for it")
    func aFollowUpSomebodyWaitsForGoesOn() async throws {
        let gate = FullSyncGate()
        let pull = Pull(parking: [1, 2])
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }
        let leaving = Self.call(gate, pull, followUp: true, note: "trigger returned")
        let staying = Self.call(gate, pull, followUp: true, note: "app returned")
        try await waitUntil { gate.queuedFollowUps == 2 }
        pull.release()
        try await waitUntil { pull.events.contains("start 2") && pull.isParked }

        leaving.cancel()
        try await waitUntil(timeout: .seconds(5)) { pull.events.contains("trigger returned") }
        #expect(pull.isParked)
        pull.release()

        #expect(await leaving.value == .skipped)
        #expect(await staying.value == .failed)
        _ = await first.value
        #expect(pull.events.contains("end 2"))
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

// `FullSyncGate`, which runs one full sync at a time. A sync trigger push that arrived during a
// pull used to be turned away, and the change it announced stayed unfetched in the background.
import Testing
@testable import TigerDuck

@MainActor
struct FullSyncGateTests {
    /// A full sync whose first run parks until `release()`. Records when each run starts and
    /// ends, and what the callers note.
    @MainActor
    private final class Pull {
        private(set) var events: [String] = []
        private var runs = 0
        private var parked: CheckedContinuation<Void, Never>?

        var isParked: Bool { parked != nil }

        func run() async {
            runs += 1
            let run = runs
            events.append("start \(run)")
            if run == 1 { await withCheckedContinuation { parked = $0 } }
            events.append("end \(run)")
        }

        func note(_ event: String) { events.append(event) }

        func release() {
            parked?.resume()
            parked = nil
        }
    }

    private static func call(
        _ gate: FullSyncGate, _ pull: Pull, followUp: Bool, mayFollow: Bool = true, note: String
    ) -> Task<Void, Never> {
        Task {
            await gate.run(followUp: followUp, mayFollow: { mayFollow }) { await pull.run() }
            pull.note(note)
        }
    }

    @Test("A trigger during a pull waits for one more pull that starts after it")
    func triggerDuringAPullGetsAFollowUp() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }
        let trigger = Self.call(gate, pull, followUp: true, note: "trigger returned")
        try await waitUntil { gate.queuedFollowUps == 1 }

        pull.release()
        await trigger.value
        await first.value

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
        for trigger in triggers { await trigger.value }
        await first.value

        #expect(pull.events.filter { $0.hasPrefix("start") } == ["start 1", "start 2"])
    }

    @Test("A pull to refresh during a pull is turned away at once")
    func plainCallDuringAPullIsTurnedAway() async throws {
        let gate = FullSyncGate()
        let pull = Pull()
        let first = Self.call(gate, pull, followUp: false, note: "first returned")
        try await waitUntil { pull.isParked }

        await Self.call(gate, pull, followUp: false, note: "second returned").value
        #expect(pull.events == ["start 1", "second returned"])

        pull.release()
        await first.value
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
        await trigger.value
        await first.value

        #expect(pull.events.filter { $0.hasPrefix("start") } == ["start 1"])
        #expect(pull.events.contains("trigger returned"))
    }
}

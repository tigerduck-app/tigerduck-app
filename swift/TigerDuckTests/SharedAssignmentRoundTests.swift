import Foundation
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct SharedAssignmentRoundTests {
    @MainActor
    private final class Rounds {
        var started: [String] = []
        var finished: [String] = []
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }

        func run(_ name: String) async -> [SDAssignment] {
            started.append(name)
            if !isOpen { await withCheckedContinuation { waiting.append($0) } }
            finished.append(name)
            return []
        }
    }

    private func start(
        _ name: String, _ rounds: Rounds, generation: Int = 1, rechecks: Bool
    ) -> Task<Void, Never> {
        Task {
            _ = await AppServiceBridge.sharedRound(generation: generation, rechecks: rechecks) {
                await rounds.run(name)
            }
        }
    }

    @Test("a round that starts while another runs for the account joins it")
    func roundsJoin() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let foreground = start("foreground", rounds, rechecks: false)
        let pullAfterPull = start("pull", rounds, rechecks: false)
        try await Task.sleep(for: .milliseconds(20))
        rounds.open()
        _ = await (launch.value, foreground.value, pullAfterPull.value)
        #expect(rounds.started == ["launch"])
    }

    @Test("a pull waits out a round that skips submissions, then rechecks in its own")
    func pullRunsItsOwnRecheck() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let launch = start("launch", rounds, rechecks: false)
        try await waitUntil { rounds.started == ["launch"] }
        let pull = start("pull", rounds, rechecks: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(rounds.started == ["launch"])
        rounds.open()
        _ = await (launch.value, pull.value)
        #expect(rounds.started == ["launch", "pull"])
        #expect(rounds.finished == ["launch", "pull"])
    }

    @Test("a round that skips submissions joins a pull")
    func launchJoinsPull() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let pull = start("pull", rounds, rechecks: true)
        try await waitUntil { rounds.started == ["pull"] }
        let foreground = start("foreground", rounds, rechecks: false)
        try await Task.sleep(for: .milliseconds(20))
        rounds.open()
        _ = await (pull.value, foreground.value)
        #expect(rounds.started == ["pull"])
    }

    @Test("the next account never joins the departing account's round")
    func roundsAreKeptPerSignIn() async throws {
        AppServiceBridge.cancelAssignmentRound()
        let rounds = Rounds()
        let departing = start("departing", rounds, generation: 1, rechecks: false)
        try await waitUntil { rounds.started == ["departing"] }
        let next = start("next", rounds, generation: 2, rechecks: false)
        try await waitUntil { rounds.started == ["departing", "next"] }
        rounds.open()
        _ = await (departing.value, next.value)
    }
}

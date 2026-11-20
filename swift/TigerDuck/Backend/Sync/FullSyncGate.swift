import Foundation


@MainActor
final class FullSyncGate {
    private(set) var isRunning = false
    private var queued: [Int: CheckedContinuation<FullSyncOutcome, Never>] = [:]
    private var following: [Int: CheckedContinuation<FullSyncOutcome, Never>] = [:]
    private var runningFollowUp: Task<Void, Never>?
    private var lastTicket = 0

    var queuedFollowUps: Int { queued.count }

    func run(
        followUp: Bool, mayFollow: @escaping () -> Bool, _ body: @escaping () async -> FullSyncOutcome
    ) async -> FullSyncOutcome {
        guard !isRunning else {
            guard followUp else { return .skipped }
            return await waitForFollowUp()
        }
        isRunning = true
        let outcome = await body()
        follow(mayFollow: mayFollow, body)
        return outcome
    }

    private func waitForFollowUp() async -> FullSyncOutcome {
        lastTicket += 1
        let ticket = lastTicket
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if Task.isCancelled { waiter.resume(returning: .skipped) } else { queued[ticket] = waiter }
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(ticket) }
        }
    }

    private func giveUp(_ ticket: Int) {
        if let waiter = queued.removeValue(forKey: ticket) {
            waiter.resume(returning: .skipped)
        } else if let waiter = following.removeValue(forKey: ticket) {
            waiter.resume(returning: .skipped)
            if following.isEmpty { runningFollowUp?.cancel() }
        }
    }

    private func follow(mayFollow: @escaping () -> Bool, _ body: @escaping () async -> FullSyncOutcome) {
        guard !queued.isEmpty, mayFollow() else {
            for waiter in queued.values { waiter.resume(returning: .skipped) }
            queued = [:]
            isRunning = false
            return
        }
        following = queued
        queued = [:]
        runningFollowUp = Task {
            let outcome: FullSyncOutcome = if Task.isCancelled { .skipped } else { await body() }
            for waiter in following.values { waiter.resume(returning: outcome) }
            following = [:]
            follow(mayFollow: mayFollow, body)
        }
    }
}

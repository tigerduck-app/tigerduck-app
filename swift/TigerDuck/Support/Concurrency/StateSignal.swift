import Foundation

@MainActor
final class StateSignal<Value> {
    var value: Value {
        didSet { resumeReady() }
    }

    private var waiters: [Int: Waiter] = [:]
    private var nextID = 0

    enum WaitOutcome {
        case ready
        case timedOut
        case cancelled
    }

    private struct Waiter {
        let isReady: (Value) -> Bool
        let continuation: CheckedContinuation<WaitOutcome, Never>
    }

    init(_ value: Value) {
        self.value = value
    }

    var waiterCount: Int { waiters.count }

    @discardableResult
    func wait(
        until isReady: @escaping (Value) -> Bool, deadline: ContinuousClock.Instant? = nil
    ) async -> WaitOutcome {
        if isReady(value) { return .ready }
        nextID += 1
        let id = nextID
        let timer = deadline.map { deadline in
            Task { [weak self] in
                try? await AppClock.sleep(until: deadline)
                self?.finish(id, .timedOut)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = Waiter(isReady: isReady, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .cancelled) }
        }
    }

    private func resumeReady() {
        for (id, waiter) in waiters where waiter.isReady(value) {
            finish(id, .ready)
        }
    }

    private func finish(_ id: Int, _ outcome: WaitOutcome) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: outcome)
    }
}

import Foundation

@MainActor
final class StateSignal<Value> {
    var value: Value {
        didSet { resumeReady() }
    }

    private var waiters: [Int: Waiter] = [:]
    private var nextID = 0

    private struct Waiter {
        let isReady: (Value) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    init(_ value: Value) {
        self.value = value
    }

    var waiterCount: Int { waiters.count }

    @discardableResult
    func wait(until isReady: @escaping (Value) -> Bool, deadline: ContinuousClock.Instant? = nil) async -> Bool {
        if isReady(value) { return true }
        nextID += 1
        let id = nextID
        let timer = deadline.map { deadline in
            Task { [weak self] in
                try? await AppClock.sleep(until: deadline)
                self?.finish(id, ready: false)
            }
        }
        defer { timer?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = Waiter(isReady: isReady, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, ready: false) }
        }
    }

    private func resumeReady() {
        for (id, waiter) in waiters where waiter.isReady(value) {
            finish(id, ready: true)
        }
    }

    private func finish(_ id: Int, ready: Bool) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: ready)
    }
}

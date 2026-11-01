import Foundation

@MainActor
final class SyncTarget {
    private typealias Waiter = (id: UUID, signIn: SignIn, resume: CheckedContinuation<Bool, Never>)

    private var pulled = SignInBound(empty: false)
    private var waiters: [Waiter] = []
    /// One is resumed at a time and resumes the next once it
    /// runs, as the executor may run tasks resumed together in another order.
    private var releasing: [(id: UUID, result: Bool, resume: CheckedContinuation<Bool, Never>)] = []
    private var resumed: UUID?

    func hasPulled(_ signIn: SignIn) -> Bool {
        signIn.isCurrent && pulled.value
    }

    func notePull(_ signIn: SignIn) {
        guard signIn.isCurrent else { return }
        pulled.set(true, for: signIn)
        release(pulled: true)
    }

    func signedOut() {
        pulled = SignInBound(empty: false)
        release(pulled: false)
    }

    func waitForPull(_ signIn: SignIn) async -> Bool {
        if hasPulled(signIn), releasing.isEmpty, resumed == nil { return true }
        guard signIn.isCurrent else { return false }
        let id = UUID()
        let pulled = await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                if Task.isCancelled {
                    resume.resume(returning: false)
                } else if hasPulled(signIn) {
                    releasing.append((id, true, resume))
                    if resumed == nil { resumeNextReleased() }
                } else {
                    waiters.append((id, signIn, resume))
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: index).resume.resume(returning: false)
            }
        }
        if resumed == id { resumeNextReleased() }
        return pulled
    }

    private func release(pulled: Bool) {
        releasing += waiters.map { ($0.id, pulled && $0.signIn.isCurrent, $0.resume) }
        waiters = []
        if resumed == nil { resumeNextReleased() }
    }

    private func resumeNextReleased() {
        guard !releasing.isEmpty else {
            resumed = nil
            return
        }
        let next = releasing.removeFirst()
        resumed = next.id
        next.resume.resume(returning: next.result)
    }
}

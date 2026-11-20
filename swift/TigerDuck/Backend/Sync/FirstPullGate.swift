import Foundation

@MainActor
final class FirstPullGate {
    enum Release: Equatable, Sendable {
        case pulled
        case dropped
    }

    private typealias Waiter = (id: UUID, signIn: SignIn, resume: CheckedContinuation<Release, Never>)

    private var pulled = SignInBound(empty: false)
    private var waiters: [Waiter] = []
    /// One is resumed at a time and resumes the next once it
    /// runs, as the executor may run tasks resumed together in another order.
    private var releasing: [(id: UUID, result: Release, resume: CheckedContinuation<Release, Never>)] = []
    private var resumed: UUID?

    func hasPulled(_ signIn: SignIn) -> Bool {
        signIn.isCurrent && pulled.value
    }

    func notePull(_ signIn: SignIn) {
        guard signIn.isCurrent else { return }
        pulled.set(true, for: signIn)
        release(.pulled)
    }

    func signedOut() {
        pulled = SignInBound(empty: false)
        release(.dropped)
    }

    func waitForPull(_ signIn: SignIn) async -> Release {
        if hasPulled(signIn), releasing.isEmpty, resumed == nil { return .pulled }
        guard signIn.isCurrent else { return .dropped }
        let id = UUID()
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Release, Never>) in
                if Task.isCancelled {
                    resume.resume(returning: .dropped)
                } else if hasPulled(signIn) {
                    releasing.append((id, .pulled, resume))
                    if resumed == nil { resumeNextReleased() }
                } else {
                    waiters.append((id, signIn, resume))
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: index).resume.resume(returning: .dropped)
            }
        }
        if resumed == id { resumeNextReleased() }
        return outcome
    }

    private func release(_ release: Release) {
        releasing += waiters.map { ($0.id, $0.signIn.isCurrent ? release : .dropped, $0.resume) }
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

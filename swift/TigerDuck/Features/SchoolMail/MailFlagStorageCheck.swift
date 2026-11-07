#if os(iOS)
import Foundation
import os

@MainActor
final class MailFlagStorageCheck {
    private struct Running {
        let id: UUID
        let signIn: SignIn
        let task: Task<Void, Never>
    }

    private weak var list: MailListViewModel?
    private var running: Running?

    init(list: MailListViewModel) {
        self.list = list
    }

    func start(for signIn: SignIn) {
        if let running, running.signIn.isCurrent { return }
        reset()
        guard !unknown.isEmpty else { return }
        let id = UUID()
        let task = Task { [weak self] in
            defer { if self?.running?.id == id { self?.running = nil } }
            while let self, let list = self.list, signIn.isCurrent {
                let unknown = self.unknown
                guard !unknown.isEmpty else { return }
                do {
                    let found = try await list.session.use(for: signIn) { client -> [String: Bool] in
                        var found: [String: Bool] = [:]
                        for folder in unknown { found[folder] = try await client.storesFlagged(folder: folder) }
                        return found
                    }
                    if signIn.isCurrent { list.folders.storesFlagged.merge(found) { $1 } }
                } catch {
                    if signIn.isCurrent { AppLogger.mail.error("Flag storage check failed: \(String(describing: error), privacy: .private)") }
                    return
                }
            }
        }
        running = Running(id: id, signIn: signIn, task: task)
    }

    func reset() {
        running?.task.cancel()
        running = nil
    }

    func wait() async { await running?.task.value }

    private var unknown: [String] {
        guard let list else { return [] }
        return list.targets.filter { list.folders.storesFlagged[$0] == nil }
    }
}
#endif

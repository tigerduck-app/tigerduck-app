import Foundation
import Defaults
import os

@MainActor
enum NotificationSettingsPushQueue {
    static var pendingDebounce: Task<Void, Never>?
    static var tail: Task<Void, Never>?
    static var generation = 0
    private(set) static var finishedLinks = 0
    private static var owedReconcile: Link?

    typealias Link = @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Bool

    static func source(
        _ snapshot: NotificationSettingsSync.DocumentSource,
        linksBeforeSnapshot: Int
    ) -> NotificationSettingsSync.DocumentSource {
        finishedLinks == linksBeforeSnapshot ? snapshot : .read
    }

    static func debounce(
        _ work: @escaping @MainActor () -> Void,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        pendingDebounce?.cancel()
        pendingDebounce = Task { @MainActor in
            await sleep(.milliseconds(250))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    @discardableResult
    static func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let queuedGeneration = generation
        let task = Task { @MainActor in
            _ = await previous?.value
            guard queuedGeneration == generation else { return }
            await work()
            finishedLinks &+= 1
        }
        tail = task
        return task
    }

    /// `reconcile` reports whether it deferred to a pending push; it runs again once a push lands
    /// with nothing left to send, so the server's document is adopted right after.
    @discardableResult
    static func enqueueReconcile(_ reconcile: @escaping Link) -> Task<Void, Never> {
        enqueueGuarded { isCurrent in
            if await reconcile(isCurrent), isCurrent() { owedReconcile = reconcile }
        }
    }

    /// `push` reports whether it landed with nothing left to send.
    @discardableResult
    static func enqueuePush(_ push: @escaping Link) -> Task<Void, Never> {
        enqueueGuarded { isCurrent in
            guard await push(isCurrent), isCurrent(), let owed = owedReconcile else { return }
            owedReconcile = nil
            enqueueReconcile(owed)
        }
    }

    private static func enqueueGuarded(
        _ work: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
    ) -> Task<Void, Never> {
        let queuedGeneration = generation
        return enqueue {
            await work { queuedGeneration == generation }
        }
    }

    static func cancelAll() {
        generation += 1
        owedReconcile = nil
        pendingDebounce?.cancel()
        pendingDebounce = nil
        tail?.cancel()
        tail = nil
    }
}

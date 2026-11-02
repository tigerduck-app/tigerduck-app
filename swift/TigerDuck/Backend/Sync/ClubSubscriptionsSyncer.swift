import Defaults
import Foundation
import os

/// Runs the club document's sync for the signed-in account while cloud sync is on. One run goes at
/// a time; calls during a run get one more run after it, which reads the server's copy again.
@MainActor
final class ClubSubscriptionsSyncer {
    /// The settings client of a sign-in, or nil when the backend has no session to send with.
    typealias Client = (SignIn) async -> SettingsDocumentClient?

    private let subscriptions: ClubSubscriptions
    private let startingSignIn: () async -> SignIn
    private let client: Client
    private let gate = FullSyncGate()
    private var snapshot: SettingsDocument?
    /// Counts finished runs, so that a full sync can tell whether its snapshot predates one.
    private(set) var finishedRuns = 0

    init(
        subscriptions: ClubSubscriptions = .shared,
        startingSignIn: @escaping () async -> SignIn = { await AccountSession.school.startingSignIn },
        client: @escaping Client
    ) {
        self.subscriptions = subscriptions
        self.startingSignIn = startingSignIn
        self.client = client
    }

    convenience init(authTokenManager: AuthTokenManager) {
        self.init { signIn in
            await authTokenManager.isLoggedIn ? SettingsDocumentClient(auth: authTokenManager.backendAuth, for: signIn) : nil
        }
    }

    /// Sends this device's changes and takes the server's. `snapshot` is the copy a full sync
    /// fetched when `finishedRuns` was `runsBeforeSnapshot`; a run of this device's own since then,
    /// or one still going, would make it stale, and the run reads the server's copy instead.
    @discardableResult
    func sync(snapshot: SettingsDocument? = nil, runsBeforeSnapshot: Int = 0) async -> FullSyncOutcome {
        guard Defaults[.cloudSyncEnabled] else { return .skipped }
        if !gate.isRunning { self.snapshot = runsBeforeSnapshot == finishedRuns ? snapshot : nil }
        return await gate.run(followUp: true, mayFollow: { Defaults[.cloudSyncEnabled] }) { await self.run() }
    }

    func retryUnacknowledged() {
        guard Defaults[.cloudSyncEnabled], subscriptions.hasUnsentChanges else { return }
        Task { await sync() }
    }

    private func run() async -> FullSyncOutcome {
        let stored = snapshot
        snapshot = nil
        defer { finishedRuns &+= 1 }
        let signIn = await startingSignIn()
        guard Defaults[.cloudSyncEnabled], let client = await client(signIn) else { return .skipped }
        let mayWrite = { signIn.isCurrent && Defaults[.cloudSyncEnabled] }
        do {
            let synced = try await ClubSubscriptionsSync.sync(
                local: subscriptions.document,
                client: client,
                stored: stored,
                mayWrite: mayWrite
            )
            guard let synced, mayWrite() else { return .skipped }
            subscriptions.adopt(synced, for: signIn)
            return .synced
        } catch {
            guard !FullSyncRunner.isCancellation(error), mayWrite() else { return .skipped }
            AppLogger.sync.error("club subscriptions sync failed: \(error.localizedDescription, privacy: .private)")
            return .failed
        }
    }
}

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
    private var snapshot = SignInBound<SettingsDocument?>(empty: nil)
    private var owed = SignInBound(empty: false)
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
        self.init(client: SettingsDocumentClient.signedIn(with: authTokenManager))
    }

    /// Whether a run failed, reading or writing, since the last one that landed for this sign-in;
    /// `retryUnacknowledged` runs again until one lands, as a change it failed to read is not
    /// marked unsent.
    var owesRun: Bool { owed.value }

    /// Sends this device's changes and takes the server's, read again.
    @discardableResult
    func sync() async -> FullSyncOutcome {
        await sync(holding: SignInBound(empty: nil))
    }

    /// `snapshot` is the copy a full sync for `signIn` fetched when `finishedRuns` was
    /// `runsBeforeSnapshot`. A run of this device's own since then, one still going, or a run for
    /// another sign-in would make it stale, and the run reads the server's copy instead.
    @discardableResult
    func sync(snapshot: SettingsDocument?, runsBeforeSnapshot: Int, for signIn: SignIn) async -> FullSyncOutcome {
        var held = SignInBound<SettingsDocument?>(empty: nil)
        if runsBeforeSnapshot == finishedRuns { held.set(snapshot, for: signIn) }
        return await sync(holding: held)
    }

    private func sync(holding held: SignInBound<SettingsDocument?>) async -> FullSyncOutcome {
        guard Defaults[.cloudSyncEnabled] else { return .skipped }
        if !gate.isRunning { snapshot = held }
        return await gate.run(followUp: true, mayFollow: { Defaults[.cloudSyncEnabled] }) { await self.run() }
    }

    func retryUnacknowledged() {
        guard Defaults[.cloudSyncEnabled], subscriptions.hasUnsentChanges || owesRun else { return }
        Task { await sync() }
    }

    private func run() async -> FullSyncOutcome {
        let held = snapshot
        snapshot = SignInBound(empty: nil)
        defer { finishedRuns &+= 1 }
        let signIn = await startingSignIn()
        let stored = held.value
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
            owed.set(false, for: signIn)
            return .synced
        } catch {
            guard !FullSyncRunner.isCancellation(error), mayWrite() else { return .skipped }
            owed.set(true, for: signIn)
            AppLogger.sync.error("club subscriptions sync failed: \(error.localizedDescription, privacy: .private)")
            return .failed
        }
    }
}

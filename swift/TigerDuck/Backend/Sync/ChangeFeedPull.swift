import Defaults
import Foundation
import os

@MainActor
final class ChangeFeedPull {
    var lastKnownRevision = 0
    private unowned let app: AppEnvironment

    init(app: AppEnvironment) {
        self.app = app
    }

    func startPolling(pollNow: Bool = true) {
        guard Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[poll] startPolling skipped — cloudSyncEnabled=false")
            app.poller.stop()
            return
        }
        app.poller.start(pollNow: pollNow)
    }

    func pollOnReturn() async {
        startPolling(pollNow: true)
        await app.poller.waitForPollInFlight()
    }

    func stopPolling() {
        app.poller.stop()
    }

    func pollRevision() async -> RevisionPollOutcome {
        await app.authService.session.withSignIn { await pollRevision(for: $0) }
    }

    private func pollRevision(for signIn: SignIn) async -> RevisionPollOutcome {
        guard Defaults[.cloudSyncEnabled] else { return .unchanged }
        guard NetworkMonitor.shared.isConnected else { return .offline }
        await app.authService.ensureBackendSignedIn()
        guard await app.authTokenManager.isLoggedIn else { return .unchanged }
        do {
            let serverRevision = try await app.pushCoordinator.fetchRevision(for: signIn)
            app.conflicts.retryOwedConflictCheck()
            AppLogger.sync.info("[poll] server revision=\(serverRevision) lastKnown=\(self.lastKnownRevision)")
            guard serverRevision > lastKnownRevision else {
                if lastKnownRevision > 0 { app.firstPullGate.notePull(signIn) }
                return .unchanged
            }
            let outcome = await syncChanges(for: signIn)
            await app.cloudSyncCoordinator.onRevisionChanged()
            return outcome
        } catch PushAPIError.httpStatus(401, _, let sent) {
            return .unauthorized(refusedAccessToken: sent?.value)
        } catch {
            AppLogger.sync.info("[poll] tick failed: \(error, privacy: .private)")
            return .failed
        }
    }

    private func syncChanges(for signIn: SignIn) async -> RevisionPollOutcome {
        let since = lastKnownRevision
        guard since > 0, !app.fullSync.gate.isRunning else {
            await app.fullSync.sync(followUpIfBusy: true)
            return .changed
        }
        let page: PushAPI.SyncChangesPage?
        do {
            page = try await app.pushCoordinator.fetchChanges(sinceRevision: since, for: signIn)
        } catch {
            AppLogger.sync.info("[feed] read failed: \(error, privacy: .private)")
            page = nil
        }
        guard mayAdvanceRevision(from: since, for: signIn), !app.fullSync.gate.isRunning else {
            return .changed
        }
        let plan = ChangeFeedPlan(page, since: since)
        AppLogger.sync.info("[feed] since=\(since) plan=\(String(describing: plan), privacy: .public)")
        switch plan {
        case .fullSync:
            await app.fullSync.sync()
        case .advance(let revision):
            await app.fullSync.retryUnsentEdits(for: signIn)
            advanceRevision(from: since, to: revision, for: signIn)
        case .reconcileSettings(let revision):
            await app.fullSync.retryUnsentEdits(for: signIn)
            await reconcileSettings(thenAdvanceFrom: since, to: revision, for: signIn)
            if lastKnownRevision == since { return .failed }
        }
        return .changed
    }

    private func reconcileSettings(thenAdvanceFrom since: Int, to revision: Int, for signIn: SignIn) async {
        await Self.reconcileSettings(
            clubs: { [app] in await app.clubSubscriptions.sync() },
            notifications: { [weak self] onSettled in await self?.settleNotifications(onSettled) },
            advance: { [weak self] in self?.advanceRevision(from: since, to: revision, for: signIn) }
        )
    }

    private func settleNotifications(_ onSettled: @escaping @MainActor () -> Void) async {
        #if os(iOS)
        if !Defaults[.notificationSettingsPushPending] {
            await app.notificationSettings.reconcile(onSettled: onSettled).value
            return
        }
        #endif
        onSettled()
    }

    /// Calls `advance` once the club document and the notification settings have both settled, so
    /// that a change either one failed to take is read again on the next poll.
    static func reconcileSettings(
        clubs: () async -> FullSyncOutcome,
        notifications: (_ onSettled: @escaping @MainActor () -> Void) async -> Void,
        advance: @escaping @MainActor () -> Void
    ) async {
        guard await clubs() != .failed else { return }
        await notifications(advance)
    }

    private func advanceRevision(from since: Int, to revision: Int, for signIn: SignIn) {
        guard mayAdvanceRevision(from: since, for: signIn) else { return }
        lastKnownRevision = revision
        app.firstPullGate.notePull(signIn)
        ServerStatusTracker.shared.noteSyncResult(true)
    }

    private func mayAdvanceRevision(from since: Int, for signIn: SignIn) -> Bool {
        Self.feedMayAdvanceRevision(
            readAfter: since,
            watermark: lastKnownRevision,
            signedOutSince: !signIn.isCurrent,
            cloudSyncEnabled: Defaults[.cloudSyncEnabled]
        )
    }

    nonisolated static func feedMayAdvanceRevision(
        readAfter since: Int,
        watermark: Int,
        signedOutSince: Bool,
        cloudSyncEnabled: Bool
    ) -> Bool {
        since == watermark
            && FullSyncRunner.fullSyncMayWrite(
                signedOutSince: signedOutSince, cloudSyncEnabled: cloudSyncEnabled, protectedDataAvailable: true
            )
    }
}

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
        await app.poller.pollInFlight()
    }

    func stopPolling() {
        app.poller.stop()
    }

    func pollRevision() async -> RevisionPollOutcome {
        guard Defaults[.cloudSyncEnabled] else { return .unchanged }
        guard NetworkMonitor.shared.isConnected else { return .offline }
        await app.authService.ensureBackendSignedIn()
        guard await app.authTokenManager.isLoggedIn else { return .unchanged }
        let ticket = app.authService.session.ticket
        do {
            let serverRevision = try await app.pushCoordinator.fetchRevision()
            app.conflicts.retryOwedConflictCheck()
            AppLogger.sync.info("[poll] server revision=\(serverRevision) lastKnown=\(self.lastKnownRevision)")
            guard serverRevision > lastKnownRevision else {
                if lastKnownRevision > 0 { app.syncTarget.notePull(ticket) }
                return .unchanged
            }
            let outcome = await syncChangesSinceLastRevision()
            await app.cloudSyncCoordinator.onRevisionChanged()
            return outcome
        } catch PushAPIError.httpStatus(401, _, let sent) {
            return .unauthorized(refused: sent?.value)
        } catch {
            AppLogger.sync.info("[poll] tick failed: \(error, privacy: .private)")
            return .failed
        }
    }

    func syncChangesSinceLastRevision() async -> RevisionPollOutcome {
        let since = lastKnownRevision
        let ticket = app.authService.session.ticket
        guard since > 0, !app.fullSync.gate.isRunning else {
            await app.fullSync.sync(followUpIfBusy: true)
            return .changed
        }
        let page: PushAPI.SyncChangesPage?
        do {
            page = try await app.pushCoordinator.fetchChanges(sinceRevision: since)
        } catch {
            AppLogger.sync.info("[feed] read failed: \(error, privacy: .private)")
            page = nil
        }
        guard mayAdvanceRevision(from: since, ticket: ticket), !app.fullSync.gate.isRunning else {
            return .changed
        }
        let plan = ChangeFeedPlan(page, since: since)
        AppLogger.sync.info("[feed] since=\(since) plan=\(String(describing: plan), privacy: .public)")
        switch plan {
        case .fullSync:
            await app.fullSync.sync()
        case .advance(let revision):
            await app.fullSync.retryUnsentEdits()
            advanceRevision(from: since, to: revision, ticket: ticket)
        case .reconcileSettings(let revision):
            await app.fullSync.retryUnsentEdits()
            await reconcileSettings(thenAdvanceFrom: since, to: revision, ticket: ticket)
            if lastKnownRevision == since { return .failed }
        }
        return .changed
    }

    private func reconcileSettings(thenAdvanceFrom since: Int, to revision: Int, ticket: AccountSession.Ticket) async {
        #if os(iOS)
        if !Defaults[.notificationSettingsPushPending] {
            await app.notificationSettings.reconcile(onSettled: { [weak self] in
                self?.advanceRevision(from: since, to: revision, ticket: ticket)
            }).value
            return
        }
        #endif
        advanceRevision(from: since, to: revision, ticket: ticket)
    }

    private func advanceRevision(from since: Int, to revision: Int, ticket: AccountSession.Ticket) {
        guard mayAdvanceRevision(from: since, ticket: ticket) else { return }
        lastKnownRevision = revision
        app.syncTarget.notePull(ticket)
        ServerStatusTracker.shared.noteSyncResult(true)
    }

    private func mayAdvanceRevision(from since: Int, ticket: AccountSession.Ticket) -> Bool {
        Self.feedMayAdvanceRevision(
            readAfter: since,
            watermark: lastKnownRevision,
            signedOutSince: !app.authService.session.isCurrent(ticket),
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

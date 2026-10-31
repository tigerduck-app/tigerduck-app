import Foundation
import os

/// Sends the outbox's edits through `OutboxSender`, one drain at a time, and the colour fills of
/// a full sync; a sign-out stops both. `CloudSyncCoordinator` runs its ticks here.
@MainActor
final class OutboxDrain {
    /// What this device may send, read at each drain.
    struct Policy {
        let syncsAssignmentMarks: @Sendable () -> Bool
        let syncsCourseIgnores: @Sendable () -> Bool
        let syncsCourseOverrides: @Sendable (_ category: String) -> Bool
        let isProtectedDataAvailable: @MainActor () -> Bool
    }

    /// Sign-outs so far and the ones still settling: a drain or a fill begun before one, or while
    /// one settles, sends nothing more.
    private struct SignOuts {
        var count = 0
        var settling = 0
    }

    /// A tick asked for while one drains runs once more after it.
    private struct Tick {
        var inFlight = false
        var askedDuringFlight = false
    }

    private let outbox: SyncOutbox
    private let sender: OutboxSender
    private let edits: QueuedEdits
    private let push: PushCoordinator
    private let policy: Policy
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Coordinator")
    private var signOuts = SignOuts()
    private var tick = Tick()
    private var sending: Task<Void, Error>?

    init(outbox: SyncOutbox, sender: OutboxSender, edits: QueuedEdits, push: PushCoordinator, policy: Policy) {
        self.outbox = outbox
        self.sender = sender
        self.edits = edits
        self.push = push
        self.policy = policy
    }

    func run(while isActive: () -> Bool) async {
        guard !tick.inFlight else {
            tick.askedDuringFlight = true
            return
        }
        tick.inFlight = true
        defer { tick.inFlight = false }
        repeat {
            tick.askedDuringFlight = false
            await drainOnce()
        } while tick.askedDuringFlight && isActive()
    }

    /// A drain the timer, `scheduleTick` or an edit started runs in a task the sign-out does not
    /// cancel, so its request is cancelled here.
    func beginSignOut() {
        signOuts.count += 1
        signOuts.settling += 1
        sending?.cancel()
    }

    func endSignOut() {
        signOuts.settling -= 1
    }

    func awaitSending() async {
        _ = await sending?.result
    }

    private func drainOnce() async {
        let protectedDataAvailable = policy.isProtectedDataAvailable()
        await outbox.loadOrGiveUp(protectedDataAvailable: protectedDataAvailable)
        guard await outbox.pendingCount() > 0 else { return }

        let signOutsBefore = signOuts.count
        let syncsMarks = policy.syncsAssignmentMarks
        let syncsIgnores = policy.syncsCourseIgnores
        let syncsOverrides = policy.syncsCourseOverrides
        await outbox.drain(holding: { op in
            switch op {
            case .assignmentOverride: return !syncsMarks()
            case .courseIgnore: return !syncsIgnores()
            case .courseAdd: return !protectedDataAvailable
            case .courseOverride(_, _, let customName, let colorHex, _, _):
                return (colorHex != nil && !syncsOverrides("course_colors"))
                    || (customName != nil && !syncsOverrides("course_names"))
            case .courseDelete: return false
            }
        }) { [weak self] op in
            guard let self else { throw CancellationError() }
            try await self.execute(op, signOutsBefore: signOutsBefore)
        }
    }

    /// Sends the colours a full sync found missing or moved, and takes the colour the backend kept
    /// when another device's landed first, unless a colour edit was queued here since. One that
    /// fails goes at the next full sync, which finds it missing again.
    func sendColorFills(_ fills: [CourseColorFill]) async {
        let signOutsBefore = signOuts.count
        let editsBefore = edits.overrideEdits
        for fill in fills {
            guard signOuts.count == signOutsBefore, signOuts.settling == 0,
                  policy.syncsCourseOverrides("course_colors") else { return }
            do {
                let reply = try await push.patchCourseOverride(
                    courseKey: fill.courseKey, colorHex: fill.colorHex, madeAt: fill.stamp
                )
                guard signOuts.count == signOutsBefore, !reply.applied.contains("color_hex"),
                      edits.colorEdit(of: fill.identity) <= editsBefore else { continue }
                sender.kept.colorKept(reply.colorHex, courseNo: fill.courseNo)
            } catch {
                logger.error("course colour fill failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Refuses an op a discard dropped after the drain picked it, and one picked before a sign-out.
    private func execute(_ op: SyncOp, signOutsBefore: Int) async throws {
        guard signOuts.count == signOutsBefore, signOuts.settling == 0 else { throw CancellationError() }
        guard !SyncOutbox.isCutOff(op, by: edits.cutoffs) else { return }
        let request = Task {
            do {
                try await self.sender.send(op, newerQueued: { await self.edits.hasNewerEdit(than: $0) })
            } catch let error where Self.isUnauthorized(error) {
                throw SyncOutboxAuthError(statusCode: 401)
            }
        }
        sending = request
        defer { if sending == request { sending = nil } }
        try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case PushAPIError.httpStatus(401, _, _) = error { return true }
        if case PushAPIError.notSignedIn = error { return true }
        return false
    }
}

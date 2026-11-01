import Foundation
import os

@MainActor
final class OutboxDrain {
    struct Policy {
        let syncsAssignmentMarks: @Sendable () -> Bool
        let syncsCourseIgnores: @Sendable () -> Bool
        let syncsCourseOverrides: @Sendable (_ category: String) -> Bool
        let isProtectedDataAvailable: @MainActor () -> Bool
    }

    private struct SignOuts {
        var count = 0
        var settling = 0
    }

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
        let isHeld: @Sendable (SyncOp) -> Bool = { op in
            switch op {
            case .assignmentOverride: return !syncsMarks()
            case .courseIgnore: return !syncsIgnores()
            case .courseAdd: return !protectedDataAvailable
            case .courseOverride(_, _, let customName, let colorHex, _, _):
                return (colorHex != nil && !syncsOverrides("course_colors"))
                    || (customName != nil && !syncsOverrides("course_names"))
            case .courseDelete: return false
            }
        }
        await outbox.drain(holding: isHeld) { [weak self] op in
            guard let self else { throw CancellationError() }
            try await BackendClient.$holdsResend.withValue({ isHeld(op) }) {
                try await self.execute(op, signOutsBefore: signOutsBefore)
            }
        }
    }

    func sendColorFills(_ fills: [CourseColorFill]) async {
        let signOutsBefore = signOuts.count
        let editsBefore = edits.overrideEdits
        for fill in fills {
            guard signOuts.count == signOutsBefore, signOuts.settling == 0,
                  policy.syncsCourseOverrides("course_colors") else { return }
            do {
                let syncsOverrides = policy.syncsCourseOverrides
                let reply = try await BackendClient.$holdsResend.withValue({ !syncsOverrides("course_colors") }) {
                    try await push.patchCourseOverride(courseKey: fill.courseKey, colorHex: fill.colorHex, madeAt: fill.stamp)
                }
                guard signOuts.count == signOutsBefore, !reply.applied.contains("color_hex"),
                      edits.colorEdit(of: fill.identity) <= editsBefore else { continue }
                sender.kept.colorKept(reply.colorHex, courseNo: fill.courseNo)
            } catch is ResendHeldError {
                return
            } catch {
                logger.error("course colour fill failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

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

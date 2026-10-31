import Defaults
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum CloudSyncState: Equatable, Sendable {
    case disabled
    case enabling(step: String)
    case active
}

@MainActor
@Observable
final class CloudSyncCoordinator {

    enum Tunables {
        static let tickInterval: TimeInterval = 5 * 60
    }

    var state: CloudSyncState { lifecycle.state }

    private(set) static weak var shared: CloudSyncCoordinator?

    static func registerShared(_ coordinator: CloudSyncCoordinator) {
        shared = coordinator
    }

    @ObservationIgnored let outbox: SyncOutbox
    @ObservationIgnored let sender: OutboxSender
    @ObservationIgnored private let edits: QueuedEdits
    @ObservationIgnored private let drain: OutboxDrain
    @ObservationIgnored private let lifecycle: CloudSyncLifecycle

    init(
        pushCoordinator: PushCoordinator,
        outbox: SyncOutbox = SyncOutbox(),
        isEnabled: Bool = Defaults[.cloudSyncEnabled],
        syncsAssignmentMarks: @escaping @Sendable () -> Bool = { SyncPolicy.current.sendsAssignmentMarks },
        syncsCourseIgnores: @escaping @Sendable () -> Bool = { SyncPolicy.current.sendsCourseIgnores },
        syncsCourseOverrides: @escaping @Sendable (_ category: String) -> Bool = {
            SyncPolicy.current.sendsCourseOverride($0)
        },
        addedCourseUpload: @escaping @MainActor (_ semester: String, _ courseNo: String)
            -> PushAPI.CourseUploadRequest? = { _, _ in nil },
        uploadsCourses: @escaping @MainActor () -> Bool = { false },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = {
            #if canImport(UIKit)
            UIApplication.shared.isProtectedDataAvailable
            #else
            true
            #endif
        },
        account: AccountSession = AccountSession(),
        courses: CourseStore = .shared,
        kept: KeptValues? = nil
    ) {
        self.outbox = outbox
        let sender = OutboxSender(
            push: pushCoordinator, addedCourseUpload: addedCourseUpload, uploadsCourses: uploadsCourses,
            isProtectedDataAvailable: isProtectedDataAvailable, account: account, courses: courses, kept: kept ?? KeptValues()
        )
        self.sender = sender
        let edits = QueuedEdits(outbox: outbox)
        self.edits = edits
        let drain = OutboxDrain(outbox: outbox, sender: sender, edits: edits, push: pushCoordinator, policy: .init(
            syncsAssignmentMarks: syncsAssignmentMarks, syncsCourseIgnores: syncsCourseIgnores,
            syncsCourseOverrides: syncsCourseOverrides, isProtectedDataAvailable: isProtectedDataAvailable
        ))
        self.drain = drain
        lifecycle = CloudSyncLifecycle(
            push: pushCoordinator, outbox: outbox, edits: edits, drain: drain, isEnabled: isEnabled
        )
        sender.onCourseAddLanded = { [weak edits] key in edits?.noteCourseAddLanded(key) }
    }

    func followPreference() {
        lifecycle.followPreference()
    }

    func settleForSignOut() async {
        await lifecycle.settleForSignOut()
    }

    func syncTick() async {
        await lifecycle.syncTick()
    }

    func onRevisionChanged() async {
        await syncTick()
    }

    func onSyncTrigger() async {
        await syncTick()
    }

    /// TigerSync switched on counts before its enable transition has left `.disabled`, so an
    /// edit made in between is queued and goes once the coordinator is active.
    private var takesEdits: Bool {
        state != .disabled || Defaults[.cloudSyncEnabled]
    }

    func sendColorFills(_ fills: [CourseColorFill]) async {
        await drain.sendColorFills(fills)
    }

    @discardableResult
    func enqueueCourseColorOverride(moodleId: String, semester: String, colorHex: String) -> Task<Void, Never>? {
        guard takesEdits else { return nil }
        return edits.enqueueOverride(.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: nil, colorHex: colorHex, locale: nil, stamp: Date()))
    }

    @discardableResult
    func enqueueCourseNameOverride(
        moodleId: String, semester: String, customName: String, locale: String?
    ) -> Task<Void, Never>? {
        guard takesEdits else { return nil }
        return edits.enqueueOverride(.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: customName, colorHex: nil, locale: locale, stamp: Date()))
    }

    func enqueueAssignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String) async {
        guard takesEdits else { return }
        let op = SyncOp.assignmentOverride(
            moodleCourseId: moodleCourseId,
            moodleAssignmentId: moodleAssignmentId,
            localStatus: localStatus, stamp: Date())
        await outbox.enqueue(op)
    }

    func pendingAssignmentOverrideIds() async -> Set<String> { await edits.pendingAssignmentOverrideIds() }

    func holdsUnsentEdits() async -> Bool { await edits.holdsUnsentEdits() }

    func pendingCourseOverrides() async -> (colors: Set<String>, names: Set<String>, edits: Int) {
        await edits.pendingCourseOverrides()
    }

    func courseOverrides(queuedAfter reading: Int) -> (colors: Set<String>, names: Set<String>) {
        edits.courseOverrides(queuedAfter: reading)
    }

    func courseOverridesToHold(
        since pending: (colors: Set<String>, names: Set<String>, edits: Int)
    ) -> (colors: Set<String>, names: Set<String>) {
        edits.courseOverridesToHold(since: pending)
    }

    /// Use Server for `categories`: drops this device's edits of them made so far, then waits out
    /// a request the outbox has in flight, so the server's values read next include it.
    func discardEdits(of categories: Set<String>, courseIgnores: Bool) async {
        await edits.discardEdits(of: categories, courseIgnores: courseIgnores)
        await drain.awaitSending()
    }

    func enqueueCourseIgnore(semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?) async {
        guard takesEdits else { return }
        await outbox.enqueue(.courseIgnore(
            semester: semester, courseNo: courseNo, moodleId: moodleId,
            moodleCourseId: moodleCourseId, ignore: ignore, stamp: Date()))
    }

    func discardCourseIgnores(semester: String? = nil, courseNo: String? = nil) async {
        await edits.discardCourseIgnores(semester: semester, courseNo: courseNo)
    }

    func pendingCourseIgnoreKeys() async -> Set<String> { await edits.pendingCourseIgnoreKeys() }

    func enqueueCourseDelete(semester: String, courseNo: String, at stamp: Date = Date()) async {
        guard takesEdits else { return }
        await outbox.enqueue(.courseDelete(semester: semester, courseNo: courseNo, stamp: stamp))
    }

    func deleteCourse(semester: String, courseNo: String, at stamp: Date = Date()) async {
        await discardCourseIgnores(semester: semester, courseNo: courseNo)
        await enqueueCourseDelete(semester: semester, courseNo: courseNo, at: stamp)
        await syncTick()
    }

    func courseDeletes<Fetched>(
        around fetch: () async throws -> Fetched
    ) async rethrows -> (fetched: Fetched, deleting: Set<String>) {
        try await edits.courseDeletes(around: fetch)
    }

    func pendingCourseDeleteKeys() async -> Set<String> { await edits.pendingCourseDeleteKeys() }

    @discardableResult
    func addCourse(semester: String, courseNo: String) -> Task<Void, Never> {
        edits.addCourse(semester: semester, courseNo: courseNo) { await self.syncTick() }
    }

    func courseAddKeys(unlandedAt date: Date) async -> Set<String> { await edits.courseAddKeys(unlandedAt: date) }

    /// How far this device's clock may be off the server's when an edit stamped here is compared
    /// with a server time. NTP keeps it within seconds; inside the margin the order cannot be told,
    /// and the edit made here is kept.
    nonisolated static let clockSkewMargin: TimeInterval = 2 * 60

    @discardableResult
    func dropCourseEdits(madeBeforeReset resetAt: Date) async -> Set<String> {
        await edits.dropCourseEdits(madeBeforeReset: resetAt)
    }

    func discardCourseDeletes(semester: String? = nil, courseKeys: Set<String>? = nil, madeBefore cutoff: Date) async {
        await edits.discardCourseDeletes(semester: semester, courseKeys: courseKeys, madeBefore: cutoff)
    }

    func requeueParkedMarks() async {
        await outbox.requeueParked()
    }

    /// A course upload has landed, so the colour and name edits parked for want of the course go again.
    func courseUploadLanded() {
        Task {
            await outbox.requeueParked()
            await syncTick()
        }
    }

    func start() {
        lifecycle.start()
    }

    func stop() {
        lifecycle.stop()
    }

    func scheduleTick(after seconds: TimeInterval = 0) {
        lifecycle.scheduleTick(after: seconds)
    }
}

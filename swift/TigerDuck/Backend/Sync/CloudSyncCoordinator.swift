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
        syncsCourseOverrides: @escaping @Sendable (_ category: SyncCategory) -> Bool = {
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
            isProtectedDataAvailable: isProtectedDataAvailable, courses: courses, kept: kept ?? KeptValues()
        )
        self.sender = sender
        let edits = QueuedEdits(outbox: outbox)
        self.edits = edits
        let drain = OutboxDrain(outbox: outbox, sender: sender, edits: edits, push: pushCoordinator, policy: .init(
            syncsAssignmentMarks: syncsAssignmentMarks, syncsCourseIgnores: syncsCourseIgnores,
            syncsCourseOverrides: syncsCourseOverrides, isProtectedDataAvailable: isProtectedDataAvailable
        ), account: account)
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

    private var isOnOrTurningOn: Bool {
        state != .disabled || Defaults[.cloudSyncEnabled]
    }

    func sendColorFills(_ fills: [CourseColorFill], for signIn: SignIn) async {
        await drain.sendColorFills(fills, for: signIn)
    }

    @discardableResult
    func enqueueCourseColorOverride(
        moodleId: String, semester: String, colorHex: String, for signIn: SignIn
    ) -> Task<Void, Never>? {
        guard isOnOrTurningOn else { return nil }
        return edits.enqueueOverride(.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: nil, colorHex: colorHex, locale: nil, stamp: Date()), for: signIn)
    }

    @discardableResult
    func enqueueCourseNameOverride(
        moodleId: String, semester: String, customName: String, locale: String?, for signIn: SignIn
    ) -> Task<Void, Never>? {
        guard isOnOrTurningOn else { return nil }
        return edits.enqueueOverride(.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: customName, colorHex: nil, locale: locale, stamp: Date()), for: signIn)
    }

    @discardableResult
    func enqueueAssignmentOverride(
        moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String, for signIn: SignIn
    ) -> Task<Void, Never>? {
        guard isOnOrTurningOn else { return nil }
        return edits.enqueueOverride(.assignmentOverride(
            moodleCourseId: moodleCourseId,
            moodleAssignmentId: moodleAssignmentId,
            localStatus: localStatus, stamp: Date()), for: signIn)
    }

    var marksAndIgnoresEnqueuing: Set<String> { edits.marksAndIgnoresEnqueuing }

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

    func discardEdits(of categories: Set<SyncCategory>, courseIgnores: Bool) async {
        await edits.discardEdits(of: categories, courseIgnores: courseIgnores)
        await drain.awaitSending()
    }

    @discardableResult
    func enqueueCourseIgnore(
        semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?, for signIn: SignIn
    ) -> Task<Void, Never>? {
        guard isOnOrTurningOn else { return nil }
        return edits.enqueueOverride(.courseIgnore(
            semester: semester, courseNo: courseNo, moodleId: moodleId,
            moodleCourseId: moodleCourseId, ignore: ignore, stamp: Date()), for: signIn)
    }

    func discardCourseIgnores(semester: String? = nil, courseNo: String? = nil) async {
        await edits.discardCourseIgnores(semester: semester, courseNo: courseNo)
    }

    func pendingCourseIgnoreKeys() async -> Set<String> { await edits.pendingCourseIgnoreKeys() }

    func enqueueCourseDelete(semester: String, courseNo: String, at stamp: Date = Date(), for signIn: SignIn) async {
        guard isOnOrTurningOn else { return }
        await outbox.enqueue(.courseDelete(semester: semester, courseNo: courseNo, stamp: stamp), for: signIn)
    }

    func deleteCourse(semester: String, courseNo: String, at stamp: Date = Date(), for signIn: SignIn) async {
        await discardCourseIgnores(semester: semester, courseNo: courseNo)
        await enqueueCourseDelete(semester: semester, courseNo: courseNo, at: stamp, for: signIn)
        await syncTick()
    }

    func courseDeletes<Fetched>(
        around fetch: () async throws -> Fetched
    ) async rethrows -> (fetched: Fetched, deleting: Set<String>) {
        try await edits.courseDeletes(around: fetch)
    }

    func pendingCourseDeleteKeys() async -> Set<String> { await edits.pendingCourseDeleteKeys() }

    @discardableResult
    func addCourse(semester: String, courseNo: String, for signIn: SignIn) -> Task<Void, Never> {
        edits.addCourse(semester: semester, courseNo: courseNo, for: signIn, afterEnqueued: { await self.syncTick() })
    }

    func courseAddKeys(unlandedAt date: Date) async -> Set<String> { await edits.courseAddKeys(unlandedAt: date) }

    nonisolated static let clockSkewMargin: TimeInterval = 2 * 60

    @discardableResult
    func dropCourseEdits(madeBeforeReset resetAt: Date) async -> Set<String> {
        await edits.dropCourseEdits(madeBeforeReset: resetAt)
    }

    func discardCourseDeletes(semester: String? = nil, courseKeys: Set<String>? = nil, madeBeforeAction cutoff: Date) async {
        await edits.discardCourseDeletes(semester: semester, courseKeys: courseKeys, madeBeforeAction: cutoff)
    }

    func requeueParkedMarks() async {
        await outbox.requeueParked()
    }

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

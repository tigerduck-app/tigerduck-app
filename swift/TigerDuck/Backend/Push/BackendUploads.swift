import Foundation

@MainActor
final class BackendUploads {
    private let client: PushAPIClient
    private let ledger: SendLedger

    var onCoursesUploaded: @MainActor () -> Void = {}

    init(client: PushAPIClient, ledger: SendLedger) {
        self.client = client
        self.ledger = ledger
    }

    static let unchangedCredentialsInterval: TimeInterval = 3600

    func updateCredentialsIfDue(moodleToken: String, moodlePrivateToken: String?, for signIn: SignIn) async throws {
        let client = client
        let ledger = ledger
        let fingerprint = SendLedger.fingerprint(of: [moodleToken, moodlePrivateToken ?? ""])
        do {
            _ = try await ledger.send(
                SendLedger.Channel.credentials, fingerprint: fingerprint,
                resend: .after(Self.unchangedCredentialsInterval), for: signIn
            ) {
                let response = try await client.updateCredentials(
                    moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken, for: signIn
                )
                if !response.updated { throw CredentialsNotUpdatedError() }
            }
        } catch is CredentialsNotUpdatedError {}
    }

    private struct CredentialsNotUpdatedError: Error {}

    nonisolated static let unchangedUploadInterval: TimeInterval = 6 * 3600

    func uploadCoursesIfChanged(
        _ request: PushAPI.CourseUploadRequest,
        semester: String,
        resend: Bool,
        addedAt stamp: Date?,
        for signIn: SignIn,
        while wanted: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let client = client
        let always = resend || request.adds?.isEmpty == false
        let sent = try await ledger.send(
            SendLedger.Channel.courses(semester),
            fingerprint: Self.fingerprint(of: request),
            resend: always ? .always : .after(Self.unchangedUploadInterval),
            pausesAfterRefusal: true,
            for: signIn, while: wanted
        ) {
            try await client.uploadCourses(request, addedAt: stamp, for: signIn)
        } == .sent
        if sent { onCoursesUploaded() }
        return sent
    }

    func uploadAssignmentsIfChanged(
        _ request: PushAPI.AssignmentUploadRequest,
        for signIn: SignIn,
        while wanted: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let client = client
        return try await ledger.send(
            SendLedger.Channel.assignments, fingerprint: Self.fingerprint(of: request),
            resend: .after(Self.unchangedUploadInterval), pausesAfterRefusal: true, for: signIn, while: wanted
        ) {
            try await client.uploadAssignments(request, for: signIn)
        } == .sent
    }

    func forgetUploads(semester: String?) {
        if let semester {
            ledger.forget(SendLedger.Channel.courses(semester))
        } else {
            ledger.forget(prefixes: [SendLedger.Channel.courses(""), SendLedger.Channel.assignments])
        }
    }

    var holdsUnsentCourseUploads: Bool {
        ledger.holdsUnsent(prefix: SendLedger.Channel.courses(""))
    }

    nonisolated static func fingerprint(of request: PushAPI.CourseUploadRequest) -> String {
        SendLedger.fingerprint(of: PushAPI.CourseUploadRequest(
            courses: request.courses.sorted { $0.courseNo < $1.courseNo },
            rosterTerms: request.rosterTerms?.sorted()
        ))
    }

    nonisolated static func fingerprint(of request: PushAPI.AssignmentUploadRequest) -> String {
        SendLedger.fingerprint(of: PushAPI.AssignmentUploadRequest(
            assignments: request.assignments.sorted { $0.moodleAssignmentId < $1.moodleAssignmentId }
        ))
    }
}

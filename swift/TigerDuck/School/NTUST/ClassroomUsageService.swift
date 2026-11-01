import Foundation

enum ClassroomUsageError: LocalizedError, Equatable {
    case notSignedIn
    case unreadable
    case dateUnavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "common_not_signed_in")
        case .unreadable, .dateUnavailable: String(localized: "error_invalid_server_response")
        }
    }
}

/// The main campus's room use for a date, from the room booking system (cour01), an ASP.NET
/// WebForms site: every postback sends back the form state of the page before it, so requests
/// run one at a time. Each read starts from a new campus page and keeps no page after it: a page
/// left over would post the date it already shows, which the site's calendar may answer from
/// that state (https://github.com/tigerduck-app/tigerduck-app/issues/513), and its state holds
/// the grid, bookers' names included.
@MainActor
final class ClassroomUsageService {
    static let queryURL = URL.knownGood(
        "https://cour01.ntust.edu.tw/classroom_user/classroom_usecondition.aspx"
    )

    static let shared = ClassroomUsageService(
        session: NTUSTSessionManager.shared.session,
        queryURL: queryURL,
        signIn: { url, credentials in
            try await SSOLoginService.ensureServiceLogin(
                session: NTUSTSessionManager.shared.session,
                serviceURL: url,
                studentId: credentials.studentId,
                password: credentials.password,
                for: credentials.signIn
            )
        }
    )

    static let todayFreshness = FreshnessPolicy(lifetime: 15 * 60)
    static let laterFreshness = FreshnessPolicy(lifetime: 3 * 60 * 60)
    /// Past this a kept day is too old to stand in for the day, so a failed reload shows the
    /// failure rather than it (https://github.com/tigerduck-app/tigerduck-app/issues/477).
    static let keptLimit = FreshnessPolicy(lifetime: 12 * 60 * 60)

    nonisolated struct KeptUsage: Equatable, Sendable {
        let usage: CampusUsage
        let fetchedAt: Date
    }

    struct Credentials: Sendable {
        let studentId: String
        let password: String
        let signIn: SignIn
    }

    typealias ServiceSignIn = @MainActor (_ serviceURL: URL, _ credentials: Credentials) async throws -> Bool
    typealias LogFailure = @MainActor (any Error) -> Void

    private let pages: ClassroomUsagePages
    private let now: @MainActor () -> Date
    private let logFailure: LogFailure

    private var reads = SignInBound(empty: Reads())
    private var epoch = 0
    private var isFetching = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        session: URLSession,
        queryURL: URL,
        signIn: @escaping ServiceSignIn,
        timeouts: (load: TimeInterval, post: TimeInterval) = (60, 15),
        now: @escaping @MainActor () -> Date = { Date() },
        logFailure: @escaping LogFailure = { AppLogger.captureError($0, context: ["service": "classroomUsage"]) }
    ) {
        pages = ClassroomUsagePages(session: session, queryURL: queryURL, signIn: signIn, timeouts: timeouts)
        self.now = now
        self.logFailure = logFailure
    }

    var siteStatus: ServerStatus { reads.value.siteStatus }

    func keptUsage(on day: Date) -> KeptUsage? {
        guard let entry = reads.value.kept[ClassroomUsageParser.dayNumber(of: day)],
              Self.keptLimit.isFresh(storedAt: entry.fetchedAt, now: now()) else { return nil }
        return entry
    }

    func usage(on day: Date, isToday: Bool, force: Bool, credentials: Credentials) async throws -> KeptUsage {
        let number = ClassroomUsageParser.dayNumber(of: day)
        let attempt = Attempt(signIn: credentials.signIn, epoch: epoch)
        try check(attempt)
        if !force, let usage = freshUsage(number, isToday: isToday) { return usage }
        return try await oneAtATime {
            try check(attempt)
            if !force, let usage = freshUsage(number, isToday: isToday) { return usage }
            let usage: CampusUsage
            do {
                usage = try await fetch(number, credentials: credentials, attempt: attempt)
                try check(attempt)
            } catch {
                noteFailure(error, for: attempt)
                throw error
            }
            let read = KeptUsage(usage: usage, fetchedAt: now())
            var updated = reads.value
            updated.siteStatus = .ok
            updated.kept[number] = read
            reads.set(updated, for: attempt.signIn)
            return read
        }
    }

    func forget() {
        reads = SignInBound(empty: Reads())
        epoch &+= 1
    }

    private struct Reads {
        var kept: [Int: KeptUsage] = [:]
        var siteStatus = ServerStatus.unknown
    }

    private struct Attempt {
        let signIn: SignIn
        let epoch: Int
    }

    private func noteFailure(_ error: any Error, for attempt: Attempt) {
        guard Self.isWorthLogging(error), (try? check(attempt)) != nil else { return }
        var updated = reads.value
        updated.siteStatus = .failed
        reads.set(updated, for: attempt.signIn)
    }

    private func check(_ attempt: Attempt) throws {
        guard attempt.signIn.isCurrent, attempt.epoch == epoch else { throw CancellationError() }
    }

    private func freshUsage(_ day: Int, isToday: Bool) -> KeptUsage? {
        guard let entry = reads.value.kept[day] else { return nil }
        let freshness = isToday ? Self.todayFreshness : Self.laterFreshness
        return freshness.isFresh(storedAt: entry.fetchedAt, now: now()) ? entry : nil
    }

    private func fetch(_ day: Int, credentials: Credentials, attempt: Attempt) async throws -> CampusUsage {
        do {
            return try await read(day, credentials: credentials, attempt: attempt)
        } catch ClassroomUsageError.unreadable {
            try check(attempt)
            NTUSTSessionManager.shared.dropServiceCookies(for: pages.queryURL)
            do {
                return try await read(day, credentials: credentials, attempt: attempt)
            } catch {
                if Self.isWorthLogging(error) { logFailure(error) }
                throw error
            }
        }
    }

    nonisolated static func isWorthLogging(_ error: any Error) -> Bool {
        !AppLogger.isCancellation(error)
    }

    private func read(_ day: Int, credentials: Credentials, attempt: Attempt) async throws -> CampusUsage {
        let scope = ClassroomUsagePages.Scope(check: { try self.check(attempt) })
        return try await pages.read(day, credentials: credentials, scope: scope)
    }

    private func oneAtATime<T>(_ body: () async throws -> T) async throws -> T {
        if isFetching {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            isFetching = true
        }
        defer {
            if waiting.isEmpty {
                isFetching = false
            } else {
                waiting.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        return try await body()
    }
}

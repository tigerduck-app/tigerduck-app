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
/// the grid, bookers' names included. Days are kept in memory only, fresh for 15 minutes today
/// and 3 hours later on and shown while they reload for up to 12 hours, while the school session
/// they came from lasts; sign-out drops them.
@MainActor
final class ClassroomUsageService {
    static let queryURL = URL.knownGood(
        "https://cour01.ntust.edu.tw/classroom_user/classroom_usecondition.aspx"
    )

    static let shared = ClassroomUsageService(
        session: NTUSTSessionManager.shared.session,
        queryURL: queryURL,
        account: .school,
        signIn: { url, credentials, isCurrent in
            try await SSOLoginService.ensureServiceLogin(
                session: NTUSTSessionManager.shared.session,
                serviceURL: url,
                studentId: credentials.studentId,
                password: credentials.password,
                isCurrent: isCurrent
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
        let signIn: AccountSession.Ticket
    }

    typealias SignIn = @MainActor (
        _ serviceURL: URL, _ credentials: Credentials, _ isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool
    typealias LogFailure = @MainActor (any Error) -> Void

    private let pages: ClassroomUsagePages
    private let now: @MainActor () -> Date
    private let logFailure: LogFailure

    private var kept: [Int: KeptUsage] = [:]
    private(set) var siteStatus = ServerStatus.unknown
    private var stateSignIn: AccountSession.Ticket?
    private var epoch = 0
    private var isFetching = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        session: URLSession,
        queryURL: URL,
        account: AccountSession,
        signIn: @escaping SignIn,
        timeouts: (load: TimeInterval, post: TimeInterval) = (60, 15),
        now: @escaping @MainActor () -> Date = { Date() },
        logFailure: @escaping LogFailure = { AppLogger.captureError($0, context: ["service": "classroomUsage"]) }
    ) {
        pages = ClassroomUsagePages(session: session, queryURL: queryURL, account: account, signIn: signIn, timeouts: timeouts)
        self.now = now
        self.logFailure = logFailure
    }

    func keptUsage(on day: Date) -> KeptUsage? {
        adoptSession()
        guard let entry = kept[ClassroomUsageParser.dayNumber(of: day)],
              Self.keptLimit.isFresh(storedAt: entry.fetchedAt, now: now()) else { return nil }
        return entry
    }

    func usage(on day: Date, isToday: Bool, force: Bool, credentials: Credentials) async throws -> KeptUsage {
        let number = ClassroomUsageParser.dayNumber(of: day)
        adoptSession()
        let ticket = Ticket(signIn: credentials.signIn, epoch: epoch)
        try check(ticket)
        if !force, let usage = freshUsage(number, isToday: isToday) { return usage }
        return try await oneAtATime {
            try check(ticket)
            if !force, let usage = freshUsage(number, isToday: isToday) { return usage }
            let usage: CampusUsage
            do {
                usage = try await fetch(number, credentials: credentials, ticket: ticket)
                try check(ticket)
            } catch {
                noteFailure(error, for: ticket)
                throw error
            }
            siteStatus = .ok
            let read = KeptUsage(usage: usage, fetchedAt: now())
            kept[number] = read
            return read
        }
    }

    func forget() {
        kept = [:]
        siteStatus = .unknown
        epoch &+= 1
    }

    private struct Ticket {
        let signIn: AccountSession.Ticket
        let epoch: Int
    }

    private var account: AccountSession { pages.account }

    private func adoptSession() {
        let signIn = account.ticket
        guard stateSignIn != signIn else { return }
        kept = [:]
        siteStatus = .unknown
        stateSignIn = signIn
    }

    private func noteFailure(_ error: any Error, for ticket: Ticket) {
        guard Self.isWorthLogging(error), (try? check(ticket)) != nil else { return }
        siteStatus = .failed
    }

    private func check(_ ticket: Ticket) throws {
        guard account.isCurrent(ticket.signIn), ticket.epoch == epoch else { throw CancellationError() }
    }

    private func freshUsage(_ day: Int, isToday: Bool) -> KeptUsage? {
        guard let entry = kept[day] else { return nil }
        let freshness = isToday ? Self.todayFreshness : Self.laterFreshness
        return freshness.isFresh(storedAt: entry.fetchedAt, now: now()) ? entry : nil
    }

    private func fetch(_ day: Int, credentials: Credentials, ticket: Ticket) async throws -> CampusUsage {
        do {
            return try await read(day, credentials: credentials, ticket: ticket)
        } catch ClassroomUsageError.unreadable {
            try check(ticket)
            NTUSTSessionManager.shared.dropServiceCookies(for: pages.queryURL)
            do {
                return try await read(day, credentials: credentials, ticket: ticket)
            } catch {
                if Self.isWorthLogging(error) { logFailure(error) }
                throw error
            }
        }
    }

    nonisolated static func isWorthLogging(_ error: any Error) -> Bool {
        !AppLogger.isCancellation(error)
    }

    private func read(_ day: Int, credentials: Credentials, ticket: Ticket) async throws -> CampusUsage {
        let scope = ClassroomUsagePages.Scope(
            isCurrent: { [account] in account.isCurrent(ticket.signIn) },
            check: { try self.check(ticket) }
        )
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

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

@MainActor
final class ClassroomUsageService {
/// The main campus's room use for a date, from the room booking system (cour01), an ASP.NET
/// WebForms site: every postback sends back the form state of the page before it, so requests
/// run one at a time. Each read starts from a new campus page and keeps no page after it: a page
/// left over would post the date it already shows, which the site's calendar may answer from
/// that state (https://github.com/tigerduck-app/tigerduck-app/issues/513), and its state holds
/// the grid, bookers' names included. Days are kept in memory only, fresh for 15 minutes today
/// and 3 hours later on and shown while they reload for up to 12 hours, while the school session
/// they came from lasts; sign-out drops them.
    static let queryURL = URL.knownGood(
        "https://cour01.ntust.edu.tw/classroom_user/classroom_usecondition.aspx"
    )

    static let shared = ClassroomUsageService(
        session: NTUSTSessionManager.shared.session,
        queryURL: queryURL,
        sessionGeneration: { NTUSTSessionManager.shared.generation },
        signIn: { url, credentials, generation in
            try await SSOLoginService.ensureServiceLogin(
                session: NTUSTSessionManager.shared.session,
                serviceURL: url,
                studentId: credentials.studentId,
                password: credentials.password,
                generation: generation
            )
        }
    )

    static let todayLifetime: TimeInterval = 15 * 60
    static let laterLifetime: TimeInterval = 3 * 60 * 60
    static let staleLimit: TimeInterval = 12 * 60 * 60
    private static let campus = "HQ"
    private static let maxPages = 20
    /// Past this a kept day is too old to stand in for the day, so a failed reload shows the
    /// failure rather than it (https://github.com/tigerduck-app/tigerduck-app/issues/477).
    private static let maxMonthSteps = 3

    nonisolated struct KeptUsage: Equatable, Sendable {
        let usage: CampusUsage
        let fetchedAt: Date
    }

    struct Credentials: Sendable {
        let studentId: String
        let password: String
        let generation: Int
    }

    typealias SignIn = @MainActor (_ serviceURL: URL, _ credentials: Credentials, _ generation: Int) async throws -> Bool
    typealias LogFailure = @MainActor (any Error) -> Void

    private let session: URLSession
    private let queryURL: URL
    private let sessionGeneration: @MainActor () -> Int
    private let signIn: SignIn
    private let timeouts: (load: TimeInterval, post: TimeInterval)
    private let now: @MainActor () -> Date
    private let logFailure: LogFailure

    private var kept: [Int: KeptUsage] = [:]
    private(set) var siteStatus = ServerStatus.unknown
    private var stateGeneration: Int?
    private var epoch = 0
    private var isFetching = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        session: URLSession,
        queryURL: URL,
        sessionGeneration: @escaping @MainActor () -> Int,
        signIn: @escaping SignIn,
        timeouts: (load: TimeInterval, post: TimeInterval) = (60, 15),
        now: @escaping @MainActor () -> Date = { Date() },
        logFailure: @escaping LogFailure = { AppLogger.captureError($0, context: ["service": "classroomUsage"]) }
    ) {
        self.session = session
        self.queryURL = queryURL
        self.sessionGeneration = sessionGeneration
        self.signIn = signIn
        self.timeouts = timeouts
        self.now = now
        self.logFailure = logFailure
    }

    func keptUsage(on day: Date) -> KeptUsage? {
        adoptSession()
        guard let entry = kept[ClassroomUsageParser.dayNumber(of: day)],
              now().timeIntervalSince(entry.fetchedAt) < Self.staleLimit else { return nil }
        return entry
    }

    func usage(on day: Date, isToday: Bool, force: Bool, credentials: Credentials) async throws -> KeptUsage {
        let number = ClassroomUsageParser.dayNumber(of: day)
        adoptSession()
        let ticket = Ticket(generation: credentials.generation, epoch: epoch)
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
        let generation: Int
        let epoch: Int
    }

    private func adoptSession() {
        let generation = sessionGeneration()
        guard stateGeneration != generation else { return }
        kept = [:]
        siteStatus = .unknown
        stateGeneration = generation
    }

    private func noteFailure(_ error: any Error, for ticket: Ticket) {
        guard Self.isWorthLogging(error), (try? check(ticket)) != nil else { return }
        siteStatus = .failed
    }

    private func check(_ ticket: Ticket) throws {
        guard ticket.generation == sessionGeneration(), ticket.epoch == epoch else { throw CancellationError() }
    }

    private func freshUsage(_ day: Int, isToday: Bool) -> KeptUsage? {
        guard let entry = kept[day] else { return nil }
        let lifetime = isToday ? Self.todayLifetime : Self.laterLifetime
        return now().timeIntervalSince(entry.fetchedAt) < lifetime ? entry : nil
    }

    private func fetch(_ day: Int, credentials: Credentials, ticket: Ticket) async throws -> CampusUsage {
        do {
            return try await read(day, credentials: credentials, ticket: ticket)
        } catch ClassroomUsageError.unreadable {
            try check(ticket)
            NTUSTSessionManager.shared.dropServiceCookies(for: queryURL)
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
        var page = try await campusPage(credentials: credentials, ticket: ticket)
        var monthSteps = 0
        while true {
            guard let step = ClassroomUsageParser.calendarStep(
                toward: day, days: page.calendarDays, monthSteps: page.monthSteps
            ) else { throw ClassroomUsageError.dateUnavailable }
            page = try await post(step, from: page, ticket: ticket)
            guard step.argument.hasPrefix("V") else { break }
            monthSteps += 1
            if monthSteps >= Self.maxMonthSteps { throw ClassroomUsageError.dateUnavailable }
        }

        var rooms: [Int: [RoomUsage]] = [:]
        while true {
            guard let grid = page.grid, page.campus == Self.campus, rooms[grid.page] == nil else {
                throw ClassroomUsageError.unreadable
            }
            rooms[grid.page] = grid.rooms
            guard let next = grid.pageLinks.filter({ rooms[$0.key] == nil }).min(by: { $0.key < $1.key }) else { break }
            guard rooms.count < Self.maxPages else { throw ClassroomUsageError.unreadable }
            page = try await post(next.value, from: page, ticket: ticket)
        }
        return CampusUsage(rooms: rooms.keys.sorted().flatMap { rooms[$0] ?? [] }, buildingNames: page.buildingNames)
    }

        // The campus page shows a grid as well, but nothing on it is known to name that grid's
        // day, which the site may keep from an earlier read, so today's date is posted too
        // (https://github.com/tigerduck-app/tigerduck-app/issues/475).
    private func campusPage(credentials: Credentials, ticket: Ticket) async throws -> ClassroomUsageParser.Page {
        var html = try await load(URLRequest(url: queryURL, timeoutInterval: timeouts.load))
        if html.map(ClassroomUsageParser.isQueryPage) != true {
            try check(ticket)
            guard try await signIn(queryURL, credentials, ticket.generation) else {
                throw ClassroomUsageError.notSignedIn
            }
            html = try await load(URLRequest(url: queryURL, timeoutInterval: timeouts.load))
        }
        guard let html, ClassroomUsageParser.isQueryPage(html) else { throw ClassroomUsageError.unreadable }
        let query = await Self.parse(html)
        // A postback can answer with a later page first, so pages are read by number. A page
        // read twice, one for another campus or more pages than the cap is no whole day.
        let campus = try await post(
            .init(target: ClassroomUsageParser.campusField, argument: ""),
            from: query,
            values: [ClassroomUsageParser.campusField: Self.campus],
            ticket: ticket
        )
        guard campus.campus == Self.campus else { throw ClassroomUsageError.unreadable }
        return campus
    }

    private func post(
        _ postback: ClassroomUsageParser.Postback,
        from page: ClassroomUsageParser.Page,
        values: [String: String] = [:],
        ticket: Ticket
    ) async throws -> ClassroomUsageParser.Page {
        let overrides = values.merging(
            ["__EVENTTARGET": postback.target, "__EVENTARGUMENT": postback.argument]
        ) { _, event in event }
        var fields = page.fields.map { (name: $0.name, value: overrides[$0.name] ?? $0.value) }
        for (name, value) in overrides.sorted(by: { $0.key < $1.key }) where !fields.contains(where: { $0.name == name }) {
            fields.append((name, value))
        }
        var request = URLRequest(url: queryURL, timeoutInterval: timeouts.post)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(queryURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = Data(SSOLoginService.formBody(fields).utf8)

        guard let html = try await load(request), ClassroomUsageParser.isQueryPage(html) else {
            throw ClassroomUsageError.unreadable
        // The query page opens on another campus, whose answer would read as a day with no rooms.
        }
        let next = await Self.parse(html)
        try check(ticket)
        return next
    }

    private func load(_ request: URLRequest) async throws -> String? {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.url?.host == queryURL.host else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parse(_ html: String) async -> ClassroomUsageParser.Page {
        await Task.detached(priority: .userInitiated) { ClassroomUsageParser.page(html) }.value
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

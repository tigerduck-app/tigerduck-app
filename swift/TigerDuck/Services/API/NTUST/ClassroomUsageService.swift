import Foundation

enum ClassroomUsageError: LocalizedError, Equatable {
    case notSignedIn
    /// A page without the room grid, even after signing in again.
    case unreadable
    /// The site's calendar offers no link to the date.
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
/// run one at a time and the last page is kept for the next date. Days are kept in memory only,
/// today's for 15 minutes and later ones for 3 hours, while the school session they came from
/// lasts; sign-out drops them with the page.
@MainActor
final class ClassroomUsageService {
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

    /// Bookings change during the day; the timetable under them does not.
    static let todayLifetime: TimeInterval = 15 * 60
    static let laterLifetime: TimeInterval = 3 * 60 * 60
    private static let campus = "HQ"
    private static let maxPages = 20
    private static let maxMonthSteps = 3

    struct Credentials: Sendable {
        let studentId: String
        let password: String
    }

    typealias SignIn = @MainActor (_ serviceURL: URL, _ credentials: Credentials, _ generation: Int) async throws -> Bool

    private let session: URLSession
    private let queryURL: URL
    private let sessionGeneration: @MainActor () -> Int
    private let signIn: SignIn

    private var kept: [Int: (usage: CampusUsage, fetchedAt: Date)] = [:]
    private var lastPage: ClassroomUsageParser.Page?
    /// The school session `kept` and `lastPage` came from.
    private var stateGeneration: Int?
    /// Moved by ``forget()``, so a fetch running across it writes nothing back.
    private var epoch = 0
    private var isFetching = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        session: URLSession,
        queryURL: URL,
        sessionGeneration: @escaping @MainActor () -> Int,
        signIn: @escaping SignIn
    ) {
        self.session = session
        self.queryURL = queryURL
        self.sessionGeneration = sessionGeneration
        self.signIn = signIn
    }

    /// The day as last read in this school session, however old, to show while it refreshes.
    func keptUsage(on day: Date) -> CampusUsage? {
        adoptSession()
        return kept[ClassroomUsageParser.dayNumber(of: day)]?.usage
    }

    func usage(on day: Date, isToday: Bool, force: Bool, credentials: Credentials) async throws -> CampusUsage {
        let number = ClassroomUsageParser.dayNumber(of: day)
        adoptSession()
        if !force, let usage = freshUsage(number, isToday: isToday) { return usage }
        return try await oneAtATime {
            // A caller that waited may find the day the one before it read.
            adoptSession()
            if !force, let usage = freshUsage(number, isToday: isToday) { return usage }
            let ticket = Ticket(generation: sessionGeneration(), epoch: epoch)
            let usage = try await fetch(number, credentials: credentials, ticket: ticket)
            try check(ticket)
            kept[number] = (usage, Date())
            return usage
        }
    }

    /// Sign-out calls this, as an account change does through it. The cour01 cookies go when
    /// the sign-out empties the session's cookie jar.
    func forget() {
        kept = [:]
        lastPage = nil
        epoch &+= 1
    }

    // MARK: - Reading a day

    private struct Ticket {
        let generation: Int
        let epoch: Int
    }

    private func adoptSession() {
        let generation = sessionGeneration()
        guard stateGeneration != generation else { return }
        kept = [:]
        lastPage = nil
        stateGeneration = generation
    }

    private func check(_ ticket: Ticket) throws {
        guard ticket.generation == sessionGeneration(), ticket.epoch == epoch else { throw CancellationError() }
    }

    private func freshUsage(_ day: Int, isToday: Bool) -> CampusUsage? {
        guard let entry = kept[day] else { return nil }
        let lifetime = isToday ? Self.todayLifetime : Self.laterLifetime
        return Date().timeIntervalSince(entry.fetchedAt) < lifetime ? entry.usage : nil
    }

    /// A page without the grid means the cour01 session lapsed or the kept form went stale, so
    /// the read starts over once from a new sign-in.
    private func fetch(_ day: Int, credentials: Credentials, ticket: Ticket) async throws -> CampusUsage {
        do {
            return try await read(day, credentials: credentials, ticket: ticket)
        } catch ClassroomUsageError.unreadable {
            lastPage = nil
            NTUSTSessionManager.shared.dropServiceCookies(for: queryURL)
            do {
                return try await read(day, credentials: credentials, ticket: ticket)
            } catch {
                AppLogger.captureError(error, context: ["service": "classroomUsage"])
                throw error
            }
        }
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

        // A postback can answer with a later page first, so pages are read by number.
        var rooms: [Int: [RoomUsage]] = [:]
        for _ in 0..<Self.maxPages {
            guard let grid = page.grid else { throw ClassroomUsageError.unreadable }
            rooms[grid.page] = grid.rooms
            guard let next = grid.pageLinks.filter({ rooms[$0.key] == nil }).min(by: { $0.key < $1.key }) else { break }
            page = try await post(next.value, from: page, ticket: ticket)
        }
        return CampusUsage(rooms: rooms.keys.sorted().flatMap { rooms[$0] ?? [] }, buildingNames: page.buildingNames)
    }

    /// The query page with the main campus chosen: the kept one, or one reached by signing in.
    private func campusPage(credentials: Credentials, ticket: Ticket) async throws -> ClassroomUsageParser.Page {
        if let lastPage { return lastPage }
        var html = try await load(URLRequest(url: queryURL))
        if html.map(ClassroomUsageParser.isQueryPage) != true {
            guard try await signIn(queryURL, credentials, ticket.generation) else {
                throw ClassroomUsageError.notSignedIn
            }
            html = try await load(URLRequest(url: queryURL))
        }
        guard let html, ClassroomUsageParser.isQueryPage(html) else { throw ClassroomUsageError.unreadable }
        let query = await Self.parse(html)
        return try await post(
            .init(target: ClassroomUsageParser.campusField, argument: ""),
            from: query,
            values: [ClassroomUsageParser.campusField: Self.campus],
            ticket: ticket
        )
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
        // 15 s, as the SSO posts use: `URLRequest`'s default is 60 s.
        var request = URLRequest(url: queryURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(queryURL.absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = Data(SSOLoginService.formBody(fields).utf8)

        guard let html = try await load(request), ClassroomUsageParser.isQueryPage(html) else {
            throw ClassroomUsageError.unreadable
        }
        let next = await Self.parse(html)
        try check(ticket)
        lastPage = next
        return next
    }

    /// A page from cour01, or nil when the request ended on another host, such as the sign-in
    /// page a lapsed session is sent to.
    private func load(_ request: URLRequest) async throws -> String? {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.url?.host == queryURL.host else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Off the main actor: the campus page runs to hundreds of kilobytes.
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

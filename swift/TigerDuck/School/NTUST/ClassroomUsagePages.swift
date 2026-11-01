import Foundation

@MainActor
struct ClassroomUsagePages {
    struct Scope {
        let check: @MainActor () throws -> Void
    }

    private static let campus = "HQ"
    private static let maxPages = 20
    private static let maxMonthSteps = 3

    let session: URLSession
    let queryURL: URL
    let signIn: ClassroomUsageService.ServiceSignIn
    let timeouts: (load: TimeInterval, post: TimeInterval)

    func read(_ day: Int, credentials: ClassroomUsageService.Credentials, scope: Scope) async throws -> CampusUsage {
        var page = try await campusPage(credentials: credentials, scope: scope)
        // The campus page shows a grid as well, but nothing on it is known to name that grid's
        // day, which the site may keep from an earlier read, so today's date is posted too
        // (https://github.com/tigerduck-app/tigerduck-app/issues/475).
        var monthSteps = 0
        while true {
            guard let step = ClassroomUsageParser.calendarStep(
                toward: day, days: page.calendarDays, monthSteps: page.monthSteps
            ) else { throw ClassroomUsageError.dateUnavailable }
            page = try await post(step, from: page, scope: scope)
            guard step.argument.hasPrefix("V") else { break }
            monthSteps += 1
            if monthSteps >= Self.maxMonthSteps { throw ClassroomUsageError.dateUnavailable }
        }

        // A postback can answer with a later page first, so pages are read by number.
        var rooms: [Int: [RoomUsage]] = [:]
        while true {
            guard let grid = page.grid, page.campus == Self.campus, rooms[grid.page] == nil else {
                throw ClassroomUsageError.unreadable
            }
            rooms[grid.page] = grid.rooms
            guard let next = grid.pageLinks.filter({ rooms[$0.key] == nil }).min(by: { $0.key < $1.key }) else { break }
            guard rooms.count < Self.maxPages else { throw ClassroomUsageError.unreadable }
            page = try await post(next.value, from: page, scope: scope)
        }
        return CampusUsage(rooms: rooms.keys.sorted().flatMap { rooms[$0] ?? [] }, buildingNames: page.buildingNames)
    }

    private func campusPage(credentials: ClassroomUsageService.Credentials, scope: Scope) async throws -> ClassroomUsageParser.Page {
        var html = try await load(URLRequest(url: queryURL, timeoutInterval: timeouts.load))
        if html.map(ClassroomUsageParser.isQueryPage) != true {
            try scope.check()
            guard try await signIn(queryURL, credentials) else {
                throw ClassroomUsageError.notSignedIn
            }
            html = try await load(URLRequest(url: queryURL, timeoutInterval: timeouts.load))
        }
        guard let html, ClassroomUsageParser.isQueryPage(html) else { throw ClassroomUsageError.unreadable }
        let query = await Self.parse(html)
        let campus = try await post(
            .init(target: ClassroomUsageParser.campusField, argument: ""),
            from: query,
            values: [ClassroomUsageParser.campusField: Self.campus],
            scope: scope
        )
        // The query page opens on another campus, whose answer would read as a day with no rooms.
        guard campus.campus == Self.campus else { throw ClassroomUsageError.unreadable }
        return campus
    }

    private func post(
        _ postback: ClassroomUsageParser.Postback,
        from page: ClassroomUsageParser.Page,
        values: [String: String] = [:],
        scope: Scope
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
        request.httpBody = Data(SSOForms.formBody(fields).utf8)

        guard let html = try await load(request), ClassroomUsageParser.isQueryPage(html) else {
            throw ClassroomUsageError.unreadable
        }
        let next = await Self.parse(html)
        try scope.check()
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
}

import Defaults
import Foundation
import Observation

nonisolated struct CourseChange: Equatable, Sendable {
    enum Kind: String, Sendable {
        case cancelled, room, start, end, note
    }

    enum Periods: Equatable, Sendable {
        case everyPeriodThatDay
        case only([String])
    }

    let id: Int
    let courseNo: String
    let kind: Kind
    let periods: Periods
    let room: String?
    let startHHmm: String?
    let endHHmm: String?
    let noteZh: String?
    let noteEn: String?

    func covers(_ period: String) -> Bool {
        switch periods {
        case .everyPeriodThatDay: true
        case .only(let periods): periods.contains(period)
        }
    }

    func note(for locale: Locale = .current) -> String? {
        locale.language.languageCode?.identifier == "zh" ? noteZh : noteEn
    }
}

nonisolated struct CourseChanges: Equatable, Sendable {
    private struct Key: Hashable {
        let courseNo: String
        let day: Date
    }

    let term: String
    private let byCourseDay: [Key: [CourseChange]]

    static let empty = CourseChanges(term: "", byCourseDay: [:])

    func changes(courseNo: String, on day: Date) -> [CourseChange] {
        byCourseDay[Key(courseNo: courseNo, day: AcademicCalendar.startOfDay(day))] ?? []
    }

    func days(courseNo: String) -> [Date] {
        byCourseDay.keys.filter { $0.courseNo == courseNo }.map(\.day).sorted()
    }

    func isCancelled(courseNo: String, on day: Date, period: String) -> Bool {
        changes(courseNo: courseNo, on: day).contains { $0.kind == .cancelled && $0.covers(period) }
    }

    static var cached: CourseChanges {
        let data = Defaults[.courseChangesCache]
        guard !data.isEmpty else { return .empty }
        return lastDecoded.value(of: data) { (try? CourseChanges(json: $0)) ?? .empty }
    }

    private static let lastDecoded = LastDecoded<CourseChanges>()
}

private nonisolated struct CourseChangesDTO: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let id: Int
        let course_no: String
        let kind: String
        let periods: [String]?
        let class_days: [String]?
        let room: String?
        let start: String?
        let end: String?
        let note_zh: String?
        let note_en: String?
    }

    let term: String
    let changes: [Row]
}

nonisolated extension CourseChanges {
    init(json: Data) throws {
        let dto = try JSONDecoder().decode(CourseChangesDTO.self, from: json)
        var index: [Key: [CourseChange]] = [:]
        for row in dto.changes {
            guard let change = CourseChange(row: row) else { continue }
            for day in (row.class_days ?? []).compactMap(AcademicCalendar.day(from:)) {
                index[Key(courseNo: change.courseNo, day: day), default: []].append(change)
            }
        }
        self.init(term: dto.term, byCourseDay: index)
    }
}

private nonisolated extension CourseChange {
    init?(row: CourseChangesDTO.Row) {
        guard let kind = Kind(rawValue: row.kind) else { return nil }
        let value: String? = switch kind {
        case .cancelled: nil
        case .room: row.room
        case .start: row.start
        case .end: row.end
        case .note: row.note_zh
        }
        guard kind == .cancelled || value?.isEmpty == false else { return nil }
        self.init(
            id: row.id,
            courseNo: row.course_no,
            kind: kind,
            periods: row.periods.map(Periods.only) ?? .everyPeriodThatDay,
            room: row.room,
            startHHmm: row.start,
            endHHmm: row.end,
            noteZh: row.note_zh,
            noteEn: row.note_en ?? row.note_zh
        )
    }
}

@MainActor
@Observable
final class CourseChangeStore {
    static let shared = CourseChangeStore()

    private(set) var revision = 0

    private let backend: BackendClient
    private let hasCompletedOnboarding: () -> Bool
    private var refreshTask: Task<Bool, Never>?
    private var endpointGeneration = 0

    init(
        session: URLSession = .shared,
        baseURL: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        hasCompletedOnboarding: @escaping () -> Bool = { Defaults[.hasCompletedOnboarding] }
    ) {
        self.backend = BackendClient(baseURL: baseURL, session: session)
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    @discardableResult
    func refresh() async -> Bool {
        guard hasCompletedOnboarding() else { return false }
        if let existing = refreshTask { return await existing.value }
        let generation = endpointGeneration
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            let changed = await self.performRefresh()
            self.clearRefreshTask(ifStartedIn: generation)
            return changed
        }
        refreshTask = task
        return await task.value
    }

    private func clearRefreshTask(ifStartedIn generation: Int) {
        if endpointGeneration == generation { refreshTask = nil }
    }

    private var hasReadableStoredFeed: Bool {
        (try? CourseChanges(json: Defaults[.courseChangesCache])) != nil
    }

    func endpointDidChange() {
        endpointGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        Defaults[.courseChangesETag] = ""
        Defaults[.courseChangesCache] = Data()
        Task { await refresh() }
    }

    private func performRefresh() async -> Bool {
        let generation = endpointGeneration
        var request = BackendRequest("GET", "calendar", "course-changes")
        request.authenticated = false
        // The ETag is ours to send; URLCache would serve its copy for the feed's max-age and hide a change.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.accepting = [304]
        let tag = Defaults[.courseChangesETag]
        if !tag.isEmpty, hasReadableStoredFeed {
            request.headers["If-None-Match"] = tag
        }

        do {
            let response = try await backend.send(request)
            guard response.status != 304 else { return false }
            let (data, http) = (response.data, response.http)
            let parsed = try CourseChanges(json: data)
            guard generation == endpointGeneration else { return false }
            let changed = parsed != CourseChanges.cached
            Defaults[.courseChangesCache] = data
            Defaults[.courseChangesETag] = http.value(forHTTPHeaderField: "ETag") ?? ""
            if changed { revision &+= 1 }
            return changed
        } catch PushAPIError.httpStatus {
            return false
        } catch {
            if !AppLogger.isCancellation(error) {
                AppLogger.captureError(error, context: ["service": "courseChangesRefresh"])
            }
            return false
        }
    }
}

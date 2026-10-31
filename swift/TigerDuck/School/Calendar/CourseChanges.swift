import Defaults
import Foundation
import Observation
import os

nonisolated struct CourseChange: Equatable, Sendable {
    enum Kind: String, Sendable {
        case cancelled, room, start, end, note
    }

    let id: Int
    let courseNo: String
    let kind: Kind
    /// Period codes the change covers; nil covers every period the course meets that day.
    let periods: [String]?
    let room: String?
    /// The new time as `HH:mm`, Taipei time.
    let start: String?
    let end: String?
    let noteZh: String?
    let noteEn: String?

    func covers(_ period: String) -> Bool {
        periods?.contains(period) ?? true
    }

    func note(for locale: Locale = .current) -> String? {
        locale.language.languageCode?.identifier == "zh" ? noteZh : noteEn
    }
}

/// The current term's course changes from `/v3/calendar/course-changes`, by course and class day.
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

    /// Every built class slot reads this, so it decodes only when the stored feed changes.
    static var cached: CourseChanges {
        let data = Defaults[.courseChangesCache]
        guard !data.isEmpty else { return .empty }
        return lastDecoded.withLock { last in
            if let last, last.data == data { return last.changes }
            let changes = (try? CourseChanges(json: data)) ?? .empty
            last = (data, changes)
            return changes
        }
    }

    private static let lastDecoded = OSAllocatedUnfairLock<(data: Data, changes: CourseChanges)?>(initialState: nil)
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
    /// Nil for a kind this build does not know and for a row missing its kind's value.
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
            periods: row.periods,
            room: row.room,
            start: row.start,
            end: row.end,
            noteZh: row.note_zh,
            noteEn: row.note_en ?? row.note_zh
        )
    }
}

@MainActor
@Observable
final class CourseChangeStore {
    static let shared = CourseChangeStore()

    /// Moves each time the stored feed changes, for the views and device surfaces that draw it.
    private(set) var revision = 0

    private let session: URLSession
    private let baseURL: () -> URL
    private let hasCompletedOnboarding: () -> Bool
    private var refreshTask: Task<Bool, Never>?
    private var endpointGeneration = 0

    init(
        session: URLSession = .shared,
        baseURL: @escaping () -> URL = PushServerConfig.resolveServerURL,
        hasCompletedOnboarding: @escaping () -> Bool = { Defaults[.hasCompletedOnboarding] }
    ) {
        self.session = session
        self.baseURL = baseURL
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    @discardableResult
    func refresh() async -> Bool {
        // A fresh install reaches here from launch code before the user has seen a screen.
        guard hasCompletedOnboarding() else { return false }
        if let existing = refreshTask { return await existing.value }
        let generation = endpointGeneration
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            let changed = await self.performRefresh()
            // A task an endpoint change replaced leaves its successor's slot alone.
            if self.endpointGeneration == generation { self.refreshTask = nil }
            return changed
        }
        refreshTask = task
        return await task.value
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
        var request = URLRequest(
            url: baseURL().appendingPathComponent("calendar").appendingPathComponent("course-changes")
        )
        // The ETag is ours to send; URLCache would serve its copy for the feed's max-age and hide a change.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let tag = Defaults[.courseChangesETag]
        // A stored feed this build cannot read is fetched again, not kept by a 304.
        if !tag.isEmpty, (try? CourseChanges(json: Defaults[.courseChangesCache])) != nil {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode != 304 else { return false }
            guard (200..<300).contains(http.statusCode) else {
                AppLogger.network.error("course changes HTTP \(http.statusCode, privacy: .public)")
                APIVersionGate.shared.note(statusCode: http.statusCode)
                return false
            }
            let parsed = try CourseChanges(json: data)
            guard generation == endpointGeneration else { return false }
            let changed = parsed != CourseChanges.cached
            Defaults[.courseChangesCache] = data
            Defaults[.courseChangesETag] = http.value(forHTTPHeaderField: "ETag") ?? ""
            if changed { revision &+= 1 }
            return changed
        } catch {
            if !AppLogger.isCancellation(error) {
                AppLogger.captureError(error, context: ["service": "courseChangesRefresh"])
            }
            return false
        }
    }
}

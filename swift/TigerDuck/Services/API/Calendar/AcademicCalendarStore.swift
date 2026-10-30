import Defaults
import Foundation
import os

@MainActor
final class AcademicCalendarStore {
    static let shared = AcademicCalendarStore()

    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "AcademicCalendar"
    )
    private var refreshTask: Task<Bool, Never>?
    private var pendingHolidayUploads = 0
    private var lastHolidayEditAt = Date.distantPast
    private var endpointGeneration = 0

    private(set) var calendar: AcademicCalendar

    init() {
        calendar = Self.loadCached()
    }

    var optedInHolidayIDs: Set<Int> { Set(Defaults[.holidayNotifyOverrides]) }

    var unacknowledgedHolidayIDs: Set<Int> {
        Set(Defaults[.holidayOverridesAwaitingUpload])
    }

    func forgetHolidayOverrides() {
        Defaults[.holidayNotifyOverrides] = []
        Defaults[.holidayOverridesAwaitingUpload] = []
        lastHolidayEditAt = .distantPast
    }

    func setHolidayAcknowledged(_ acknowledged: Bool, holidayID: Int) {
        var ids = unacknowledgedHolidayIDs
        if acknowledged { ids.remove(holidayID) } else { ids.insert(holidayID) }
        Defaults[.holidayOverridesAwaitingUpload] = ids.sorted()
    }

    func isClassDay(_ day: Date) -> Bool {
        calendar.isClassDay(day, optedIn: optedInHolidayIDs)
    }

    @discardableResult
    func refresh() async -> Bool {
        if let existing = refreshTask { return await existing.value }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            let changed = await self.performRefresh()
            self.refreshTask = nil
            return changed
        }
        refreshTask = task
        return await task.value
    }

    private func performRefresh() async -> Bool {
        let generation = endpointGeneration
        let url = PushServerConfig.resolveServerURL()
            .appendingPathComponent("calendar")
            .appendingPathComponent("semesters")
        var request = URLRequest(url: url)
        // The ETag is ours to send; URLCache would serve its copy for the feed's max-age and hide a change.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let tag = Defaults[.academicCalendarETag]
        if !tag.isEmpty {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            ServerStatusTracker.shared.noteBackendReachable(
                http.statusCode == 304 || (200..<300).contains(http.statusCode)
            )
            if http.statusCode == 304 { return false }
            guard (200..<300).contains(http.statusCode) else {
                logger.error("academic calendar HTTP \(http.statusCode, privacy: .public)")
                APIVersionGate.shared.note(statusCode: http.statusCode)
                return false
            }
            let dto = try JSONDecoder().decode(AcademicCalendarDTO.self, from: data)
            let parsed = AcademicCalendar(dto: dto)
            guard generation == endpointGeneration else {
                logger.info("dropped a calendar answered by a previous endpoint")
                return false
            }
            let changed = parsed != calendar
            calendar = parsed
            Defaults[.academicCalendarETag] = http.value(forHTTPHeaderField: "ETag") ?? ""
            if let encoded = try? JSONEncoder().encode(parsed) {
                Defaults[.academicCalendarCache] = encoded
            }
            if changed {
                NotificationCenter.default.post(
                    name: AppConstants.dataDidUpdate, object: nil
                )
            }
            return changed
        } catch {
            ServerStatusTracker.shared.noteBackendReachable(false)
            logger.error(
                "academic calendar refresh failed: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    @discardableResult
    func setNotify(_ notify: Bool, forHoliday holidayID: Int) -> Bool {
        var ids = Set(Defaults[.holidayNotifyOverrides])
        let before = ids
        if notify { ids.insert(holidayID) } else { ids.remove(holidayID) }
        guard ids != before else { return false }
        Defaults[.holidayNotifyOverrides] = Array(ids).sorted()
        lastHolidayEditAt = Date()
        return true
    }

    func endpointDidChange() {
        forgetCachedCalendar()
        Task { await refresh() }
    }

    func forgetCachedCalendar() {
        endpointGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        Defaults[.academicCalendarETag] = ""
        Defaults[.academicCalendarCache] = Data()
        calendar = .empty
    }

    @discardableResult
    func applySyncedOverrides(_ ids: Set<Int>, fetchedAt: Date) -> Bool {
        guard pendingHolidayUploads == 0, fetchedAt > lastHolidayEditAt else {
            logger.info("holiday overrides from sync ignored — a local toggle is newer")
            return false
        }
        let local = optedInHolidayIDs
        var merged = ids
        for id in unacknowledgedHolidayIDs {
            if local.contains(id) { merged.insert(id) } else { merged.remove(id) }
        }
        guard merged != local else { return false }
        Defaults[.holidayNotifyOverrides] = merged.sorted()
        return true
    }

    func beginHolidayUpload() { pendingHolidayUploads += 1 }
    func endHolidayUpload() { pendingHolidayUploads = max(0, pendingHolidayUploads - 1) }

    private static func loadCached() -> AcademicCalendar { AcademicCalendar.cached }
}

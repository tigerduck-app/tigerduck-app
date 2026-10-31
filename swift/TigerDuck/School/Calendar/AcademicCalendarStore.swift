import Defaults
import Foundation
import Observation
import os

@MainActor
@Observable
final class AcademicCalendarStore: AccountScoped {
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

    static func forgetAccount(in storage: AccountStorage) {
        shared.forgetHolidayOverrides()
    }

    /// The holiday's setting here and when it was made, which has no time for a setting made
    /// before the time was kept.
    func holidayEdit(_ holidayID: Int) -> (notify: Bool, madeAt: Date?) {
        (optedInHolidayIDs.contains(holidayID), Defaults[.holidayOverrideEditTimes][String(holidayID)])
    }

    func forgetHolidayOverrides() {
        Defaults[.holidayNotifyOverrides] = []
        Defaults[.holidayOverridesAwaitingUpload] = []
        Defaults[.holidayOverrideEditTimes] = [:]
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
        var request = BackendRequest("GET", "calendar", "semesters")
        request.authenticated = false
        // The ETag is ours to send; URLCache would serve its copy for the feed's max-age and hide a change.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.accepting = [304]
        let tag = Defaults[.academicCalendarETag]
        if !tag.isEmpty {
            request.headers["If-None-Match"] = tag
        }

        do {
            let response = try await BackendClient(session: .shared).send(request)
            let (data, http) = (response.data, response.http)
            ServerStatusTracker.shared.noteBackendReachable(true)
            if http.statusCode == 304 { return false }
            let dto = try JSONDecoder().decode(AcademicCalendarDTO.self, from: data)
            let parsed = AcademicCalendar(dto: dto)
            guard generation == endpointGeneration else {
                logger.info("dropped a calendar answered by a previous endpoint")
                return false
            }
            let changed = parsed != calendar
            if changed { calendar = parsed }
            Defaults[.academicCalendarETag] = http.value(forHTTPHeaderField: "ETag") ?? ""
            if let encoded = try? JSONEncoder().encode(parsed) {
                Defaults[.academicCalendarCache] = encoded
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
        Defaults[.holidayOverrideEditTimes][String(holidayID)] = lastHolidayEditAt
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
        let replaced = Set(merged.symmetricDifference(local).map(String.init))
        Defaults[.holidayOverrideEditTimes] = Defaults[.holidayOverrideEditTimes].filter { !replaced.contains($0.key) }
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
        return true
    }

    /// The setting the backend kept over this device's, one another device made later; it counts
    /// as synced, not as an edit here.
    func applyKeptNotify(_ notify: Bool, forHoliday holidayID: Int) {
        var ids = Set(Defaults[.holidayNotifyOverrides])
        if notify { ids.insert(holidayID) } else { ids.remove(holidayID) }
        Defaults[.holidayOverrideEditTimes][String(holidayID)] = nil
        guard ids != Set(Defaults[.holidayNotifyOverrides]) else { return }
        Defaults[.holidayNotifyOverrides] = ids.sorted()
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
    }

    func beginHolidayUpload() { pendingHolidayUploads += 1 }
    func endHolidayUpload() { pendingHolidayUploads = max(0, pendingHolidayUploads - 1) }

    private static func loadCached() -> AcademicCalendar { AcademicCalendar.cached }
}

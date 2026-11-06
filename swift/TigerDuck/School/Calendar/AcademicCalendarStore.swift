import Defaults
import Foundation
import Observation
import os

@MainActor
@Observable
final class AcademicCalendarStore: AccountScoped {
    static let shared = AcademicCalendarStore(clock: .shared)

    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "AcademicCalendar"
    )
    private var refreshTask: Task<Bool, Never>?
    private var pendingHolidayUploads = 0
    private var lastHolidayEditAt = Date.distantPast
    private var endpointGeneration = 0
    let clock: SyncClock

    private(set) var calendar: AcademicCalendar

    init(clock: SyncClock) {
        self.clock = clock
        calendar = Self.loadCached()
    }

    var optedInHolidayIDs: Set<Int> { Set(Defaults[.holidayNotifyOverrides]) }

    var unacknowledgedHolidayIDs: Set<Int> {
        Set(Defaults[.holidayOverridesAwaitingUpload])
    }

    static func forgetAccount(in storage: AccountStorage) {
        shared.forgetHolidayOverrides()
    }

    func holidayEdit(_ holidayID: Int) -> (notify: Bool, madeAt: Date?) {
        (optedInHolidayIDs.contains(holidayID), Defaults[.holidayOverrideEditTimes][String(holidayID)])
    }

    func forgetHolidayOverrides() {
        Defaults.reset(.holidayNotifyOverrides, .holidayOverridesAwaitingUpload, .holidayOverrideEditTimes)
        lastHolidayEditAt = .distantPast
    }

    func setHolidayAcknowledged(_ acknowledged: Bool, holidayID: Int, for signIn: SignIn) {
        var ids = unacknowledgedHolidayIDs
        if acknowledged { ids.remove(holidayID) } else { ids.insert(holidayID) }
        Defaults[.holidayOverridesAwaitingUpload, for: signIn] = ids.sorted()
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

        do {
            let answer = try await BackendClient(session: .shared).revalidate(request, etag: Defaults[.academicCalendarETag])
            ServerStatusTracker.shared.noteBackendReachable(true)
            guard let copy = answer?.copy else { return false }
            let dto = try JSONDecoder().decode(AcademicCalendarDTO.self, from: copy.body)
            let parsed = AcademicCalendar(dto: dto)
            guard generation == endpointGeneration else {
                logger.info("dropped a calendar answered by a previous endpoint")
                return false
            }
            let changed = parsed != calendar
            if changed { calendar = parsed }
            Defaults[.academicCalendarETag] = copy.etag ?? ""
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
    func setNotify(_ notify: Bool, forHoliday holidayID: Int, for signIn: SignIn) -> Bool {
        guard signIn.isCurrent else { return false }
        var ids = Set(Defaults[.holidayNotifyOverrides])
        let before = ids
        if notify { ids.insert(holidayID) } else { ids.remove(holidayID) }
        guard ids != before else { return false }
        Defaults[.holidayNotifyOverrides, for: signIn] = Array(ids).sorted()
        Defaults[.holidayOverrideEditTimes, for: signIn][String(holidayID)] = clock.stamp()
        lastHolidayEditAt = clock.mark()
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
    func applySyncedOverrides(_ ids: Set<Int>, fetchedAt: Date, holding held: Set<Int> = [], for signIn: SignIn) -> Bool {
        guard signIn.isCurrent else { return false }
        guard pendingHolidayUploads == 0, fetchedAt > lastHolidayEditAt else {
            logger.info("holiday overrides from sync ignored — a local toggle is newer")
            return false
        }
        let local = optedInHolidayIDs
        var merged = ids
        for id in unacknowledgedHolidayIDs.union(held) {
            if local.contains(id) { merged.insert(id) } else { merged.remove(id) }
        }
        guard merged != local else { return false }
        Defaults[.holidayNotifyOverrides, for: signIn] = merged.sorted()
        let replaced = Set(merged.symmetricDifference(local).map(String.init))
        Defaults[.holidayOverrideEditTimes, for: signIn] = Defaults[.holidayOverrideEditTimes].filter { !replaced.contains($0.key) }
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
        return true
    }

    func applyNotifyTheBackendKept(_ notify: Bool, forHoliday holidayID: Int, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        var ids = Set(Defaults[.holidayNotifyOverrides])
        if notify { ids.insert(holidayID) } else { ids.remove(holidayID) }
        Defaults[.holidayOverrideEditTimes, for: signIn][String(holidayID)] = nil
        guard ids != Set(Defaults[.holidayNotifyOverrides]) else { return }
        Defaults[.holidayNotifyOverrides, for: signIn] = ids.sorted()
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
    }

    func beginHolidayUpload() { pendingHolidayUploads += 1 }
    func endHolidayUpload() { pendingHolidayUploads = max(0, pendingHolidayUploads - 1) }

    private static func loadCached() -> AcademicCalendar { AcademicCalendar.cached }
}

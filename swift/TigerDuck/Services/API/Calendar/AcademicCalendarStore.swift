import Defaults
import Foundation
import os

/// Holds the school's academic calendar and keeps it fresh.
///
/// Outside the cloud-sync gate that wraps every other backend call: the
/// calendar is the school's published dates, with no user, device id or
/// account, so signed-out and sync-off installs fetch it with an
/// unauthenticated GET. Holiday suppression of class reminders should not
/// depend on opting into sync. The decoded calendar is cached so the widget
/// extension and an offline cold launch can still answer "is today a holiday".
@MainActor
final class AcademicCalendarStore {
    static let shared = AcademicCalendarStore()

    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "AcademicCalendar"
    )
    private var refreshTask: Task<Bool, Never>?
    /// Holiday toggles this device has made but not yet uploaded. See
    /// ``applySyncedOverrides(_:fetchedAt:)``.
    private var pendingHolidayUploads = 0
    /// When this device last changed a holiday override. See
    /// ``applySyncedOverrides(_:fetchedAt:)``.
    private var lastHolidayEditAt = Date.distantPast
    /// Bumped whenever the app changes which backend it talks to, so a
    /// response already on its way back from the previous one can be told
    /// apart from a current one. See ``forgetCachedCalendar()``.
    private var endpointGeneration = 0

    /// The calendar as of the last successful fetch.
    private(set) var calendar: AcademicCalendar

    init() {
        calendar = Self.loadCached()
    }

    /// Holidays this user asked to keep hearing about.
    var optedInHolidayIDs: Set<Int> { Set(Defaults[.holidayNotifyOverrides]) }

    /// Toggles the backend has not acknowledged. Survives a relaunch, because
    /// the failure this protects against — an upload that never landed — is
    /// exactly the one that outlives the process that made it.
    var unacknowledgedHolidayIDs: Set<Int> {
        Set(Defaults[.holidayOverridesAwaitingUpload])
    }

    /// Drop the departing account's holiday choices.
    ///
    /// Both sets are account-scoped and neither key says so. Left behind,
    /// the next person to sign in on this device inherits the previous
    /// user's quiet days — and the awaiting-upload set is worse than
    /// inherited, because the retry would push those choices into the new
    /// account over its own session.
    func forgetHolidayOverrides() {
        Defaults[.holidayNotifyOverrides] = []
        Defaults[.holidayOverridesAwaitingUpload] = []
        lastHolidayEditAt = .distantPast
    }

    /// Record that `holidayID` is waiting on the server, or has reached it.
    func setHolidayAcknowledged(_ acknowledged: Bool, holidayID: Int) {
        var ids = unacknowledgedHolidayIDs
        if acknowledged { ids.remove(holidayID) } else { ids.insert(holidayID) }
        Defaults[.holidayOverridesAwaitingUpload] = ids.sorted()
    }

    /// Whether class reminders, the Live Activity and the next-class widgets
    /// stay quiet on `day`.
    func suppressesClasses(on day: Date = Date()) -> Bool {
        calendar.suppressesClasses(on: day, optedIn: optedInHolidayIDs)
    }

    /// Whether `day` is a class day — in term, and not a quiet holiday.
    func isClassDay(_ day: Date) -> Bool {
        calendar.isClassDay(day, optedIn: optedInHolidayIDs)
    }

    /// Re-fetch, cheaply.
    ///
    /// Called on every foreground. The server answers 304 with no body when
    /// nothing changed, so the common case is one conditional GET. A failure
    /// keeps the cached calendar: an unreachable backend must not turn
    /// suppression off for a device that already knows the dates. Concurrent
    /// calls share one in-flight request, so scene activation and a
    /// pull-to-refresh landing together make one.
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
        // Which backend this request is for; checked again before committing,
        // since `Task.cancel()` cannot unsend a request and an arrived response
        // would be decoded and stored without asking whether it is still wanted.
        let generation = endpointGeneration
        let url = PushServerConfig.resolveServerURL()
            .appendingPathComponent("calendar")
            .appendingPathComponent("semesters")
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let tag = Defaults[.academicCalendarETag]
        if !tag.isEmpty {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            // This account-free GET runs on every app open, TigerSync on or off:
            // the one way the status dot learns whether the backend is up on a
            // device that does not sync. 304 counts: a served, empty answer.
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
            // The calendar screen builds its rows once per load and caches them
            // by day; `CalendarViewModel.load` listens on this, or newly
            // published dates would not show until the next cold launch.
            if changed {
                NotificationCenter.default.post(
                    name: AppConstants.dataDidUpdate, object: nil
                )
            }
            return changed
        } catch {
            ServerStatusTracker.shared.noteBackendReachable(false)
            logger.error(
                "academic calendar refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Record whether the user wants class reminders on `holidayID`.
    ///
    /// The local write is what makes the guard behave; the upload only makes
    /// the user's other devices agree. Returns whether anything changed, so
    /// the caller can skip a pointless round trip.
    @discardableResult
    func setNotify(_ notify: Bool, forHoliday holidayID: Int) -> Bool {
        var ids = Set(Defaults[.holidayNotifyOverrides])
        let before = ids
        if notify { ids.insert(holidayID) } else { ids.remove(holidayID) }
        guard ids != before else { return false }
        Defaults[.holidayNotifyOverrides] = Array(ids).sorted()
        // Wall clock, not `AppClock`: this is compared against the sync
        // path's own `Date()`, and a DEBUG clock override would put the two
        // in different eras.
        lastHolidayEditAt = Date()
        return true
    }

    /// Drop everything the previous backend told us, and refetch.
    ///
    /// The cache and ETag are endpoint-scoped but do not say so. Another
    /// deployment can return a matching ETag (by chance, or on the same
    /// upstream backend) whose 304 pins the old dates, and a failed refresh
    /// keeps the cache so an outage cannot switch suppression off; both are
    /// wrong once the endpoint moves. Not awaited: the caller is a Save button,
    /// and until the new backend answers, the empty calendar fails open.
    func endpointDidChange() {
        forgetCachedCalendar()
        Task { await refresh() }
    }

    /// The clearing half of ``endpointDidChange()``, without the refetch, so
    /// a test can pin it without reaching the network.
    func forgetCachedCalendar() {
        endpointGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        Defaults[.academicCalendarETag] = ""
        Defaults[.academicCalendarCache] = Data()
        calendar = .empty
    }

    /// Replace the local set from a cloud-sync snapshot taken at `fetchedAt`.
    ///
    /// A response that crosses a tap carries the pre-tap state and would flip
    /// the switch back. So it is ignored unless `fetchedAt` is after the last
    /// local edit and no upload is pending (a fetch after the tap can still
    /// predate the upload); the next sync settles it. Unacknowledged toggles are
    /// re-imposed on the snapshot, as `setHolidayNotify` promises a local setting
    /// stands even if its upload failed; the payload's other holidays still land.
    func applySyncedOverrides(_ ids: Set<Int>, fetchedAt: Date) {
        guard pendingHolidayUploads == 0, fetchedAt > lastHolidayEditAt else {
            logger.info("holiday overrides from sync ignored — a local toggle is newer")
            return
        }
        let local = optedInHolidayIDs
        var merged = ids
        for id in unacknowledgedHolidayIDs {
            if local.contains(id) { merged.insert(id) } else { merged.remove(id) }
        }
        Defaults[.holidayNotifyOverrides] = merged.sorted()
    }

    /// Brackets an in-flight holiday upload, so ``applySyncedOverrides(_:)``
    /// knows not to overwrite a choice the server has not heard yet.
    func beginHolidayUpload() { pendingHolidayUploads += 1 }
    func endHolidayUpload() { pendingHolidayUploads = max(0, pendingHolidayUploads - 1) }

    /// A payload this build cannot read is worse than none — it would pin a
    /// stale calendar forever — so `AcademicCalendar.cached` falls back to
    /// empty and the next refresh repopulates.
    private static func loadCached() -> AcademicCalendar { AcademicCalendar.cached }
}

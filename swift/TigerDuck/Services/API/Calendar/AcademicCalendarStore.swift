import Defaults
import Foundation
import os

/// Holds the school's academic calendar and keeps it fresh.
///
/// Deliberately outside the cloud-sync gate that wraps every other backend
/// call. The calendar carries no user, no device id and no account — it is
/// the school's published dates — so it is fetched over an unauthenticated
/// GET that signed-out and sync-off installs both make. Suppressing class
/// reminders on a public holiday should not depend on whether someone opted
/// into syncing their timetable.
///
/// The decoded calendar is cached so the widget extension and a cold launch
/// with no network can still answer "is today a holiday".
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

    /// Re-fetch, cheaply.
    ///
    /// Called on every foreground. The server answers 304 with no body when
    /// nothing changed, so the common case costs one conditional GET. Any
    /// failure leaves the cached calendar in place — an unreachable backend
    /// must not turn suppression off for a device that already knows the
    /// dates.
    ///
    /// Concurrent calls share one in-flight request: scene activation and a
    /// pull-to-refresh landing together should not produce two.
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
        // Which backend this request belongs to. Checked again before the
        // response is committed: `Task.cancel()` cannot unsend a request, and
        // a response that has already arrived is decoded and stored without
        // ever asking whether it is still wanted.
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
            // The calendar screen builds its rows once per load and caches
            // them by day; without this it would keep showing the calendar
            // that was on disk when the tab appeared, and newly published
            // dates would not surface until the next cold launch. This is
            // the notification `CalendarViewModel.load` already listens on.
            if changed {
                NotificationCenter.default.post(
                    name: AppConstants.dataDidUpdate, object: nil
                )
            }
            return changed
        } catch {
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
    /// The cache and the ETag are both endpoint-scoped, and neither says so.
    /// An ETag is opaque, so a different deployment can hand back one that
    /// matches by coincidence — or the same one, if both are running the
    /// upstream backend — and the 304 that follows would pin the old
    /// server's dates. A refresh that simply fails leaves them in place for
    /// the same reason: `performRefresh` keeps the cache on error on
    /// purpose, so that an unreachable backend cannot switch suppression
    /// off. Both behaviours are right while the endpoint is fixed and wrong
    /// the moment it moves, which is what this exists for.
    ///
    /// The refresh is not awaited: the caller is a Save button, and an empty
    /// calendar is the honest state until the new backend answers. Empty
    /// fails open — no terms reads as in-session, no holidays suppresses
    /// nothing — so the gap shows classes rather than hiding them.
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
    /// A sync response describes the server as it was when the request left,
    /// so one that crosses a tap on the wire carries the state from *before*
    /// that tap. Applying it flips the switch back under the user's finger
    /// and leaves this device disagreeing with the server it has just told.
    ///
    /// Two conditions, because neither covers the other's gap:
    ///
    /// - `fetchedAt` older than the last local edit means the snapshot cannot
    ///   possibly know about that edit, whether or not its upload has landed.
    /// - A snapshot fetched *after* the tap can still predate the upload
    ///   arriving, so it reports the old value with a newer timestamp; the
    ///   pending count covers that window.
    ///
    /// Either way the local edit is the newer fact. The next sync settles it.
    ///
    /// Toggles the server has never acknowledged survive the snapshot
    /// regardless. An upload that failed leaves the server honestly reporting
    /// the old value, so applying it wholesale would hand the user's choice
    /// back — and `setHolidayNotify` promises the opposite: the setting made
    /// on this device stands whether or not the upload succeeded. They are
    /// re-imposed on top of the snapshot rather than discarding it, so the
    /// *other* holidays in the same payload still land.
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

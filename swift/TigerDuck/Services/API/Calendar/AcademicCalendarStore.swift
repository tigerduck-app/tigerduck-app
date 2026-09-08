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

    /// The calendar as of the last successful fetch.
    private(set) var calendar: AcademicCalendar

    init() {
        calendar = Self.loadCached()
    }

    /// Holidays this user asked to keep hearing about.
    var optedInHolidayIDs: Set<Int> { Set(Defaults[.holidayNotifyOverrides]) }

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
        return true
    }

    /// Replace the local set from a cloud-sync snapshot.
    func applySyncedOverrides(_ ids: Set<Int>) {
        Defaults[.holidayNotifyOverrides] = Array(ids).sorted()
    }

    /// A payload this build cannot read is worse than none — it would pin a
    /// stale calendar forever — so `AcademicCalendar.cached` falls back to
    /// empty and the next refresh repopulates.
    private static func loadCached() -> AcademicCalendar { AcademicCalendar.cached }
}

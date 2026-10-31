import WidgetKit
import Foundation
import os
import TigerDuckCore

nonisolated struct NextClassProvider: TimelineProvider {
    var snapshotFileURL = SharedAppGroup.snapshotFileURL

    func placeholder(in context: Context) -> NextClassEntry {
        NextClassEntry(
            date: Date(),
            current: nil,
            next: Self.sampleCourse(),
            nextDay: .today,
            accentHex: WatchSnapshot.defaultAccentHex,
            languageTag: nil,
            relevance: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        let snapshot = loadSnapshot()
        completion(entry(for: snapshot, at: AppClock.now(), date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let snapshot = loadSnapshot()
        completion(timeline(for: snapshot, now: AppClock.now()))
    }

    /// `now` and the class times are on the app clock, which the debug clock can move. WidgetKit
    /// runs on the real clock, so each entry and the reload are dated with their real instants.
    func timeline(for snapshot: WatchSnapshot?, now: Date) -> Timeline<NextClassEntry> {
        let courses = snapshot?.courses ?? []
        let quietDays = snapshot?.quietDays ?? []
        let cal = TaipeiTime.calendar

        var boundaries: Set<Date> = [now]
        if let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) {
            boundaries.insert(midnight)
        }
        for dayOffset in 0...1 {
            guard let anchor = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            for c in NextClassResolver.todaysClasses(courses: courses, now: anchor, quietDays: quietDays) {
                if let s = combine(hhmm: c.startHHmm, with: anchor), s > now { boundaries.insert(s) }
                if let e = combine(hhmm: c.endHHmm, with: anchor), e > now { boundaries.insert(e) }
            }
        }
        let entries = boundaries.sorted().map { boundary in
            entry(for: snapshot, at: boundary, date: AppClock.realTime(forApp: boundary))
        }

        let reloadAt = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 4, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(6 * 3600)

        return Timeline(entries: entries, policy: .after(AppClock.realTime(forApp: reloadAt)))
    }

    /// The phone's last push as the Watch app saved it. Also applies the push's debug clock
    /// override: the widget runs in its own process, so its `AppClock` follows the phone's only
    /// through this file, as the Watch app's does through `ScheduleStore`.
    func loadSnapshot() -> WatchSnapshot? {
        var snapshot: WatchSnapshot?
        if FileManager.default.fileExists(atPath: snapshotFileURL.path) {
            do {
                let data = try Data(contentsOf: snapshotFileURL)
                snapshot = try JSONDecoder().decode(WatchSnapshot.self, from: data)
            } catch {
                WatchAppLogger.widget.error("widget loadSnapshot failed: \(error.localizedDescription)")
            }
        }
        AppClock.setOverride(ClockOverride.decode(snapshotJSON: snapshot?.clockOverrideJSON))
        return snapshot
    }

    private func entry(for snapshot: WatchSnapshot?, at appNow: Date, date: Date) -> NextClassEntry {
        let r = NextClassResolver.resolve(
            courses: snapshot?.courses ?? [], now: appNow, quietDays: snapshot?.quietDays ?? []
        )
        return NextClassEntry(
            date: date,
            current: r.current,
            next: r.next,
            nextDay: r.nextDay,
            accentHex: snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex,
            languageTag: snapshot?.languageTag,
            relevance: relevance(for: r, now: appNow)
        )
    }

    private func combine(hhmm: String, with anchor: Date) -> Date? {
        let cal = TaipeiTime.calendar
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var dc = cal.dateComponents([.year, .month, .day], from: anchor)
        dc.hour = h; dc.minute = m
        return cal.date(from: dc)
    }

    private func relevance(for r: NextClassResolver.Result, now: Date) -> TimelineEntryRelevance? {
        let low = TimelineEntryRelevance(score: 30, duration: 0)
        let daysAhead: Int
        switch r.nextDay {
        case .today: daysAhead = 0
        case .tomorrow: daysAhead = 1
        case .later: return low
        }
        guard let next = r.next,
              let day = TaipeiTime.calendar.date(byAdding: .day, value: daysAhead, to: now),
              let start = combine(hhmm: next.startHHmm, with: day)
        else { return low }
        let minutesUntil = start.timeIntervalSince(now) / 60
        guard minutesUntil > 0, minutesUntil <= 30 else { return low }
        return TimelineEntryRelevance(score: 90, duration: minutesUntil * 60)
    }

    static func sampleCourse() -> WatchCourse {
        WatchCourse(
            id: "sample-1-3",
            courseNo: "SAMPLE",
            name: "資料結構",
            teacher: "張教授",
            classroom: "D101",
            colorHex: WatchSnapshot.defaultAccentHex,
            weekday: 1,
            startHHmm: "10:20",
            endHHmm: "11:10",
            periodLabel: "3-4"
        )
    }
}

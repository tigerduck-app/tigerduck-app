import WidgetKit
import Foundation

struct NextClassProvider: TimelineProvider {

    func placeholder(in context: Context) -> NextClassEntry {
        NextClassEntry(
            date: Date(),
            current: nil,
            next: Self.sampleCourse(),
            accentHex: WatchSnapshot.defaultAccentHex,
            relevance: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        let snapshot = loadSnapshot()
        let r = NextClassResolver.resolve(courses: snapshot?.courses ?? [], now: Date())
        completion(NextClassEntry(
            date: Date(),
            current: r.current,
            next: r.next,
            accentHex: snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex,
            relevance: relevance(for: r, now: Date())
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let snapshot = loadSnapshot()
        let accent = snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex
        let courses = snapshot?.courses ?? []

        var entries: [NextClassEntry] = []
        let now = Date()
        let cal = Calendar(identifier: .iso8601)
        let raw = cal.component(.weekday, from: now)
        let iso = ((raw + 5) % 7) + 1
        let today = courses.filter { $0.weekday == iso }

        // Boundary times in chronological order: each class start + each class end.
        var boundaries: [Date] = [now]
        for c in today {
            if let s = combine(hhmm: c.startHHmm, with: now), s > now { boundaries.append(s) }
            if let e = combine(hhmm: c.endHHmm, with: now), e > now { boundaries.append(e) }
        }
        // De-dup and sort
        let unique = Array(Set(boundaries)).sorted()

        for ts in unique {
            let r = NextClassResolver.resolve(courses: courses, now: ts)
            entries.append(NextClassEntry(
                date: ts,
                current: r.current,
                next: r.next,
                accentHex: accent,
                relevance: relevance(for: r, now: ts)
            ))
        }

        // Reload tomorrow at 04:00 local
        let reloadAt = cal.nextDate(
            after: now,
            matching: DateComponents(hour: 4, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(6 * 3600)

        completion(Timeline(entries: entries, policy: .after(reloadAt)))
    }

    // MARK: - Helpers

    private func loadSnapshot() -> WatchSnapshot? {
        let url = SharedAppGroup.snapshotFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(WatchSnapshot.self, from: data)
        } catch {
            WatchAppLogger.widget.error("widget loadSnapshot failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func combine(hhmm: String, with anchor: Date) -> Date? {
        let cal = Calendar(identifier: .iso8601)
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var dc = cal.dateComponents([.year, .month, .day], from: anchor)
        dc.hour = h; dc.minute = m
        return cal.date(from: dc)
    }

    private func relevance(for r: NextClassResolver.Result, now: Date) -> TimelineEntryRelevance? {
        guard let next = r.next, let start = combine(hhmm: next.startHHmm, with: now) else {
            return TimelineEntryRelevance(score: 30, duration: 0)
        }
        let minutesUntil = start.timeIntervalSince(now) / 60
        if minutesUntil <= 30 {
            return TimelineEntryRelevance(score: 90, duration: minutesUntil * 60)
        }
        return TimelineEntryRelevance(score: 30, duration: 0)
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

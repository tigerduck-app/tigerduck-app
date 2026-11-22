import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@Suite("Demo account dates")
@MainActor
struct DemoDatesTests {
    private static let days = ["2026-11-23T09:00", "2027-03-02T21:30"]

    private static func day(_ text: String) throws -> Date { try #require(DemoTime.date(text)) }

    /// Monday 1 to Sunday 7, as `demo.json` counts weekdays.
    private static func weekday(of dayKey: String) throws -> Int {
        let sundayFirst = TaipeiTime.calendar.component(.weekday, from: try day(dayKey))
        return (sundayFirst + 5) % 7 + 1
    }

    private static func offsets(on today: Date) throws -> [TimeInterval] {
        let fixture = try #require(DemoFixture.load(from: .main, today: today))
        let mail = try #require(MailDemoFixture.load(from: .main, in: .en, today: today))
        let start = TaipeiTime.calendar.startOfDay(for: today)
        let dates = (fixture.assignments ?? []).compactMap { $0.assignment(in: .en)?.dueDate }
            + (fixture.calendar ?? []).enumerated().compactMap { $1.event(index: $0)?.date }
            + (fixture.bulletins ?? []).enumerated().compactMap { $1.detail(index: $0).postedAt }
            + mail.folders.values.flatMap { $0.map(\.date) }
        return dates.map { $0.timeIntervalSince(start) }.sorted()
    }

    @Test("on two different days the demo's dates sit the same distance from today")
    func datesFollowToday() throws {
        let measured = try Self.days.map { try Self.offsets(on: try Self.day($0)) }

        #expect(measured[0].count == 14)
        #expect(measured[0] == measured[1])
    }

    @Test("the assignments are due in the coming days, with one done and none overdue, and the mail is recent")
    func theDataLooksCurrent() throws {
        let today = try Self.day(Self.days[0])
        let fixture = try #require(DemoFixture.load(from: .main, today: today))
        let assignments = (fixture.assignments ?? []).compactMap { $0.assignment(in: .en) }
        let mail = try #require(MailDemoFixture.load(from: .main, in: .en, today: today))
        let newest = try #require(mail.folders.values.flatMap { $0.map(\.date) }.max())

        #expect(assignments.filter { !$0.isCompleted }.allSatisfy { ($0.dueDate ?? .distantPast) > today })
        #expect(assignments.filter(\.isCompleted).count == 1)
        #expect(newest < today)
        #expect(today.timeIntervalSince(newest) < 3 * 86_400)
    }

    @Test("course changes and club activities keep their weekdays on any day")
    func weekdayBoundDataKeepsItsWeekdays() throws {
        for text in Self.days {
            let today = try Self.day(text)
            let fixture = try #require(DemoFixture.load(from: .main, today: today))
            for change in fixture.courseChanges ?? [] {
                let row = change.row(from: today)
                #expect(try Self.weekday(of: try #require(row.class_days?.first)) == change.weekday)
            }
            for club in fixture.clubs ?? [] {
                let placed = club.activities(in: .en, from: today)
                #expect(try placed.map { try Self.weekday(of: try #require($0.date)) } == (club.activities ?? []).map(\.weekday))
            }
        }
    }

    @Test("the bundled fixture and the demo mail are moved by the same days")
    func theMailAndTheRestMoveAlike() throws {
        func gap(_ fixture: DemoFixture?, _ mail: MailDemoFixture?) throws -> TimeInterval {
            let due = try #require(fixture?.assignments?.first?.assignment(in: .en)?.dueDate)
            return due.timeIntervalSince(try #require(mail?.folders.values.flatMap { $0.map(\.date) }.max()))
        }
        let today = try Self.day(Self.days[0])

        let bundled = try gap(DemoFixture.bundled, MailDemoFixture.shared)
        let loaded = try gap(DemoFixture.load(from: .main, today: today), MailDemoFixture.load(from: .main, today: today))

        #expect(bundled == loaded)
    }

    @Test("every string the shift moves in demo.json reads as a date")
    func theShiftMovesOnlyDates() throws {
        func moved(_ old: Any, _ new: Any) -> [String] {
            switch (old, new) {
            case let (old as String, new as String): old == new ? [] : [old]
            case let (old as [Any], new as [Any]): zip(old, new).flatMap { moved($0, $1) }
            case let (old as [String: Any], new as [String: Any]): old.flatMap { key, value in new[key].map { moved(value, $0) } ?? [] }
            default: []
            }
        }
        let raw = try Data(contentsOf: try #require(Bundle.main.url(forResource: "demo", withExtension: "json")))
        let shifted = DemoTime.shifted(raw, to: try Self.day(Self.days[0]))

        let changed = moved(try JSONSerialization.jsonObject(with: raw), try JSONSerialization.jsonObject(with: shifted))

        #expect(changed.count > 40)
        #expect(changed.filter { DemoTime.date($0) == nil } == [])
    }

    @Test("a day just before Taipei's midnight and one just after move the anchor to their own days")
    func theShiftFollowsTaipeiDays() throws {
        let json = Data(#"{"anchor":"2026-10-15","due":"2026-10-15T08:00","list":["2026-10-14","B11308964"]}"#.utf8)
        func moved(on today: String) throws -> [String: Any] {
            let shifted = DemoTime.shifted(json, to: try Self.day(today))
            return try #require(try JSONSerialization.jsonObject(with: shifted) as? [String: Any])
        }

        let before = try moved(on: "2026-11-23T23:59:30+08:00")
        let after = try moved(on: "2026-11-24T00:00:30+08:00")

        #expect(before["due"] as? String == "2026-11-23T08:00")
        #expect(before["list"] as? [String] == ["2026-11-22", "B11308964"])
        #expect(after["due"] as? String == "2026-11-24T08:00")
    }
}

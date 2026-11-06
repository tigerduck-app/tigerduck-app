import Foundation
import SwiftUI
import Testing
@testable import TigerDuckWatch_Watch_App
import TigerDuckCore

@MainActor
struct NowNextRoomAndRangeTests {

    private let longName = "資料結構與演算法專題研究與實作"
    private let longRoom = "IB-1005 階梯教室"

    private func course(name: String = "資料結構與演算法", room: String = "TR-412") -> WatchCourse {
        WatchCourse(
            id: "A", courseNo: "A", name: name, teacher: "", classroom: room, colorHex: "#4ECDC4",
            weekday: 1, startHHmm: "10:20", endHHmm: "12:10", periodLabel: "3-4"
        )
    }

    private func entry(
        current: WatchCourse? = nil, next: WatchCourse? = nil, day: NextClassResolver.Day = .today, languageTag: String? = nil
    ) -> NextClassEntry {
        NextClassEntry(
            date: Date(), current: current, next: next, nextDay: day, currentSpan: nil,
            accentHex: "#FF8800", languageTag: languageTag, relevance: nil
        )
    }

    private func mondayAt(_ hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        return TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 5, day: 11, hour: parts[0], minute: parts[1]))!
    }

    private let policy = WatchVisualStylePolicy(preset: .default)
    private let zh = WatchLanguage(tag: "zh-Hant")

    @Test func thePageCaptionsEachClassWithItsRange() {
        #expect(ClassCard(title: "現在", course: course(), span: nil, policy: policy, language: zh).caption == "現在 · 10:20–12:10")
        #expect(ClassCard(title: "下一堂", course: course(), span: nil, policy: policy, language: zh).caption == "下一堂 · 10:20–12:10")
    }

    @Test func voiceOverReadsEachRangeInWords() {
        #expect(ClassCard(title: "現在", course: course(), span: nil, policy: policy, language: zh).spokenCaption == "現在, 10:20 至 12:10")
        #expect(RectangularView(entry: entry(current: course(), languageTag: "zh-Hant")).spokenSubhead == "10:20 至 12:10")
        #expect(RectangularView(entry: entry(next: course(), day: .tomorrow, languageTag: "zh-Hant")).spokenSubhead == "明天 10:20 至 12:10")
    }

    @Test func voiceOverHearsTheRoomAndTheRangeOnTheCornerAndCircular() throws {
        #expect(entry(current: course(), languageTag: "zh-Hant").spokenSummary == "TR-412, 10:20 至 12:10")
        #expect(entry(next: course(), day: .tomorrow, languageTag: "zh-Hant").spokenSummary == "TR-412, 明天 10:20 至 12:10")
        let none = try localizedValue("watch_no_upcoming_classes", in: "zh-Hant")
        #expect(entry(languageTag: "zh-Hant").spokenSummary == none)
    }

    @Test func theInlineComplicationShowsOnlyTheRoom() {
        #expect(InlineView(entry: entry(current: course())).text == "TR-412")
        #expect(InlineView(entry: entry(next: course())).text == "TR-412 · 10:20")
    }

    @Test func theRoomStaysWholeWhenTheNameIsLong() {
        let long = entry(current: course(name: longName, room: longRoom))
        #expect(InlineView(entry: long).text == longRoom)
        #expect(CircularView(entry: long).label == longRoom)
        #expect(CornerView(entry: long).label == longRoom)
        #expect(RectangularView(entry: long).room == longRoom)
    }

    @Test func aClassWithoutARoomIsNamedInstead() {
        let online = entry(current: course(room: ""))
        #expect(InlineView(entry: online).text == "資料結構與演算法")
        #expect(CircularView(entry: online).label == "資料結構與演算法")
        #expect(CornerView(entry: online).label == "資料結構與演算法")
        #expect(RectangularView(entry: online).room == nil)
    }

    @Test func theClassOnNowCarriesItsSpanForTheLiveProgress() {
        let on = NextClassResolver.resolve(courses: [course()], now: mondayAt("11:00"))
        #expect(on.currentSpan == mondayAt("10:20")...mondayAt("12:10"))
        let before = NextClassResolver.resolve(courses: [course()], now: mondayAt("09:00"))
        #expect(before.next?.id == "A")
        #expect(before.currentSpan == nil)
    }

    @Test func theCountdownReservesTheWidthOfItsLongestValue() {
        #expect(ClassCountdown(span: mondayAt("10:20")...mondayAt("11:10"), tint: .orange).widest == "00:00")
        #expect(ClassCountdown(span: mondayAt("10:20")...mondayAt("12:10"), tint: .orange).widest == "000:00")
        #expect(ClassCountdown(span: mondayAt("10:20")...mondayAt("10:25"), tint: .orange).widest == "0:00")
    }
}

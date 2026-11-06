import Foundation
import SwiftUI
import Testing
@testable import TigerDuckWatch_Watch_App
import TigerDuckCore

/// A text left whole draws the same with head and tail truncation; the room is drawn in a colour
/// nothing else uses, so its ink can be counted.
@MainActor
struct WatchRoomLayoutTests {

    private let magenta = (red: 255, green: 0, blue: 255)
    private let longName = "Advanced Topics in Data Structures and Algorithms"
    private let en = WatchLanguage(tag: "en")

    private func course(name: String, room: String, start: String = "10:20", end: String = "12:10") -> WatchCourse {
        WatchCourse(
            id: "A", courseNo: "A", name: name, teacher: "", classroom: room, colorHex: "#FF00FF",
            weekday: 1, startHHmm: start, endHHmm: end, periodLabel: "3-4"
        )
    }

    /// Not begun, so the bar is empty and the countdown stands still between renders.
    private var notBegun: ClosedRange<Date> {
        Date().addingTimeInterval(3_600)...Date().addingTimeInterval(3_600 + 110 * 60)
    }

    private func entry(current: WatchCourse? = nil, next: WatchCourse? = nil, day: NextClassResolver.Day = .today) -> NextClassEntry {
        NextClassEntry(
            date: Date(), current: current, next: next, nextDay: day, currentSpan: current == nil ? nil : notBegun,
            accentHex: "#FF8800", languageTag: "en", relevance: nil
        )
    }

    private func keepsItsRoom(_ view: some View, width: CGFloat, height: CGFloat?) throws {
        let squeezed = try #require(renderOnWatch(view, width: width, height: height))
        let roomy = try #require(renderOnWatch(view, width: 1_000, height: height))
        let whole = inkCount(roomy, near: magenta)
        #expect(whole > 0)
        #expect(Double(inkCount(squeezed, near: magenta)) >= 0.95 * Double(whole))
    }

    private func drawsWhole(_ view: some View, width: CGFloat, height: CGFloat) throws {
        let head = try #require(renderOnWatch(view, width: width, height: height, truncation: .head))
        let tail = try #require(renderOnWatch(view, width: width, height: height, truncation: .tail))
        #expect(rgbaBytes(head) == rgbaBytes(tail))
    }

    @Test func thePageCardKeepsTheWholeRoomBesideALongName() throws {
        let card = ClassCard(
            title: "NOW", course: course(name: longName, room: "IB-1005 國際大樓階梯教室"), span: notBegun,
            policy: WatchVisualStylePolicy(preset: .default), language: en
        )
        try keepsItsRoom(card, width: 192, height: nil)
    }

    @Test func theRectangularKeepsTheWholeRoomBesideALongNameAndRange() throws {
        let view = RectangularView(entry: entry(current: course(name: longName, room: "IB-1005 階梯教室")))
        try keepsItsRoom(view, width: 193, height: 82)
    }

    @Test func theRectangularShowsTheNextClassesRoomAndDayAndTimeWhole() throws {
        let tomorrow = entry(next: course(name: "Networks", room: "IB-1005 階梯教室", start: "09:10", end: "12:00"), day: .tomorrow)
        try drawsWhole(RectangularView(entry: tomorrow), width: 193, height: 82)
    }

    // The corner is left out: ImageRenderer draws it flat, and on the face the system lays the
    // curved room out and can clip a long one, which the view can only shrink to half size.
    @Test func theCircularShowsALongRoomWhole() throws {
        try drawsWhole(CircularView(entry: entry(current: course(name: longName, room: "IB-1005 階梯教室"))), width: 50, height: 50)
    }

    @Test func aThreeHourClassStillLeavesRoomForTheBar() throws {
        let span = Date().addingTimeInterval(-90 * 60)...Date().addingTimeInterval(90 * 60)
        let row = try #require(renderOnWatch(ClassCountdown(span: span, tint: Color(red: 1, green: 0, blue: 1)), width: 193, height: 20))
        #expect(inkCount(row, near: magenta) > 200)
    }
}

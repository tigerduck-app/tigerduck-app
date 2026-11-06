import Foundation
import Testing
import TigerDuckCore

struct TimeRangeTests {
    @Test func aRangeIsBothTimesJoinedByAnEnDash() {
        #expect(TimeRange.text("08:10", "09:00") == "08:10–09:00")
    }

    @Test func minutesAfterMidnightArePaddedToTwentyFourHourClockTimes() {
        #expect(TimeRange.text(from: 490, to: 1215) == "08:10–20:15")
        #expect(TimeRange.text(from: 0, to: 65) == "00:00–01:05")
        #expect(TimeRange.text(from: 1380, to: 1439) == "23:00–23:59")
    }

    @Test func aPartialRangeShowsOnlyTheSideItHas() {
        #expect(TimeRange.partial(start: "10:30", end: "12:20") == "10:30–12:20")
        #expect(TimeRange.partial(start: "10:30", end: nil) == "10:30")
        #expect(TimeRange.partial(start: nil, end: "12:20") == "–12:20")
        #expect(TimeRange.partial(start: nil, end: nil) == nil)
    }

    @Test func theSpokenRangeFillsTheLocalizedTimeRangeKey() {
        var asked: [String] = []
        let spoken = TimeRange.spoken("10:20", "12:10") { resource in
            asked.append(resource.key)
            return "%1$@ to %2$@"
        }
        #expect(spoken == "10:20 to 12:10")
        #expect(asked == ["a11y_time_range"])
        #expect(TimeRange.spoken(from: 0, to: 65) { _ in "%1$@ to %2$@" } == "00:00 to 01:05")
    }

    @Test func aLiveActivitySubtitleKeepsTheFormTheBackendParses() {
        let subtitle = TimeRange.liveActivitySubtitle("10:20", "12:10")
        #expect(subtitle == "10:20 - 12:10")
        #expect(TimeRange.times(ofLiveActivitySubtitle: subtitle)?.start == "10:20")
        #expect(TimeRange.times(ofLiveActivitySubtitle: subtitle)?.end == "12:10")
        #expect(TimeRange.times(ofLiveActivitySubtitle: "10:20–12:10") == nil)
        #expect(TimeRange.times(ofLiveActivitySubtitle: "") == nil)
    }

    @Test func aSubtitleIsReadAsTimesOnlyWhenBothSidesAreTimes() {
        #expect(TimeRange.times(ofLiveActivitySubtitle: "10:20 - 12:10").map { [$0.start, $0.end] } == ["10:20", "12:10"])
        #expect(TimeRange.times(ofLiveActivitySubtitle: "Intro - Lab") == nil)
        #expect(TimeRange.times(ofLiveActivitySubtitle: "10:20 -  12:10") == nil)
        #expect(TimeRange.times(ofLiveActivitySubtitle: "10:20 - Lab") == nil)
    }
}
